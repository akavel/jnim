import macros, tables, sets, jni_wrapper, jni_api, strutils, sequtils
# FIXME: add dali dependency in jnim.nimble
import dali / [types, instrs]

type MethodDescr = object
  name: string
  retType: string
  argTypes: seq[string]

const
  JnimPackageName = "io.github.yglukhov.jnim"
  FinalizerName = "_0"
  PointerFieldName = "_1"
  InitializerName = "_2"
  JniExportedFunctionPrefix = "Java_" & JnimPackageName.replace('.', '_') & "_Jnim_00024"

proc initMethodDescr(name, retType: string, argTypes: seq[string]): MethodDescr =
  result.name = name
  result.retType = retType
  result.argTypes = argTypes

proc toWords(a: NimNode, res: var seq[string]) =
  case a.kind
  of nnkArgList:
    var i = 0
    while i < a.len and a[i].kind in {nnkCommand, nnkIdent, nnkInfix}:
      toWords(a[i], res)
      inc i
  of nnkCommand:
    for n in a:
      toWords(n, res)
  of nnkIdent:
    res.add($a)
  of nnkInfix:
    a[0].expectKind(nnkIdent)
    a[1].expectKind(nnkIdent)
    assert($a[0] == "*")
    res.add($a[1] & "*")
    toWords(a[2], res)
  else:
    echo "Enexpected node: ", repr(a)
    doAssert(false)

proc extractArguments(a: NimNode): tuple[className, parentClass: string, interfaces: seq[string], body: NimNode, isPublic: bool] =
  var words: seq[string]
  a.toWords(words)
  var state: range[0 .. 4]
  for w in words:
    case state
    of 0: # Waiting class name
      result.className = w
      if w[^1] == '*':
        result.isPublic = true
        result.className = w[0 .. ^2]
      state = 1
    of 1: # Waiting extends keyword
      if w == "extends":
        state = 2
      elif w == "implements":
        state = 4
      else:
        assert(false)
    of 2: # Waiting superclass
      result.parentClass = w
      state = 3
    of 3: # Waiting implements keyword
      assert(w == "implements")
      state = 4
    of 4: # Waiting interface name
      result.interfaces.add(w)

  if a[^1].kind != nnkIdent:
    result.body = a[^1]

const jnimGlue {.strdefine.} = "Jnim.java"

var
  javaGlue {.compileTime.} = newStringOfCap(1000000)
  imports {.compileTime.}: HashSet[string]
  classCursor {.compileTime.} = 0
  importCursor {.compileTime.} = 0

proc importNameFromFqcn(fq: string): string =
  if '.' in fq and not fq.startsWith("Jnim."):
    let dollarIdx = fq.find('$')
    if dollarIdx == -1:
      return fq
    else:
      return fq[0 .. dollarIdx - 1]

proc isConstr(m: MethodDescr): bool = m.name == "new"

proc genJavaGlue(className, parentClass: string, interfaces: seq[string], isPublic: bool, methodDefs: seq[MethodDescr], staticSection, emitSection: string) =
  if classCursor == 0:

    javaGlue = "package " & JnimPackageName & ";\n"
    importCursor = javaGlue.len
    javaGlue &= """
public class Jnim {
public interface __NimObject {}
public static native void """ & FinalizerName & """(long p);
"""
    classCursor = javaGlue.len
    javaGlue &= "}\n"
    imports = initSet[string]()

  echo "className: ", className, " public: ", isPublic
  echo "super: ", parentClass
  echo "interfaces: ", interfaces
  echo "body: ", repr(body)
  # echo "cur javaglue.len: ", javaGlue.len

  var newImports = newStringOfCap(10000)

  proc noDollarFqcn(s: string): string = s.replace('$', '.')

  proc addImport(s: string) =
    if s.len != 0 and s notin imports:
      imports.incl(s)
      newImports &= "import "
      newImports &= s
      newImports &= ";\n"

  # addImport("ExportTestClass")
  # addImport(className)

  var classDef = newStringOfCap(100000)
  classDef &= "public static class "
  classDef &= className
  if parentClass.len != 0:
    classDef &= " extends "
    classDef &= parentClass.noDollarFqcn()
    addImport(importNameFromFqcn(parentClass))

  classDef &= " implements __NimObject"
  for f in interfaces:
    classDef &= ", "
    classDef &= f.noDollarFqcn()
    addImport(importNameFromFqcn(f))
  classDef &= " {\n"
  if staticSection.len != 0:
    classDef &= "static { " & staticSection & "}\n"
  classDef &= emitSection
  classDef &= '\n'

  classDef &= """
protected void finalize() throws Throwable { super.finalize(); """ & FinalizerName & "(" & PointerFieldName & "); " & PointerFieldName & """ = 0; }
private long """ & PointerFieldName & """;
private native void """ & InitializerName & """();
"""

  for m in methodDefs:
    if m.isConstr:
      classDef &= "public " & className
    else:
      classDef &= "public native "
      classDef &= m.retType
      classDef &= " "
      classDef &= m.name

    classDef &= "("
    for i, a in m.argTypes:
      if i != 0: classDef &= ", "
      classDef &= a.noDollarFqcn
      classDef &= " _" & $i
    classDef &= ")"

    if m.isConstr:
      classDef &= "{ super("
      for i, a in m.argTypes:
        if i != 0: classDef &= ", "
        classDef &= "_" & $i
      classDef &= "); " & InitializerName & "(); }\n"
    else:
      classDef &= ";\n"

  classDef &= "}\n\n"

  if newImports.len != 0:
    javaGlue.insert(newImports, importCursor)
    importCursor += newImports.len
    classCursor += newImports.len

  javaGlue.insert(classDef, classCursor)
  classCursor += classDef.len
  # echo javaGlue
  # echo "new javaglue.len: ", javaGlue.len

  # echo classDef

  # var s {.global.}: string
  # s.insert($a & "\n")
  writeFile(jnimGlue, javaGlue)

var dexGlue {.compileTime.}: seq[string]

proc genDexGlue(className, parentClass: string, interfaces: seq[string], isPublic: bool, methodDefs: seq[MethodDescr], staticSection, emitSection: string) =
  # NOTE: as of Nim 1.0.2, some stdlib packages used by dali are broken at
  # compile time (see e.g.: https://github.com/nim-lang/Nim/issues/11761), so
  # we must use a workaround of writing an external file and compiling it
  # via command line.

  func cls(javaClassPath: string): Type =
    if javaClassPath.startsWith "Jnim.":
      # FIXME: sometimes we're getting class names without full path from jexport
      cls(javaClassPath[5..^1])
    elif not javaClassPath.contains ".":
      # FIXME: sometimes we're getting class names without full path from jexport
      cls(JnimPackageName & ".Jnim$" & javaClassPath)
    else:
      "L" & javaClassPath.replace(".", "/") & ";"

  let
    Object = cls"java.lang.Object"
    # TODO: make it possible to customize the path of the package
    Jnim = cls(JnimPackageName & ".Jnim")
    NimObject = cls(JnimPackageName & ".Jnim$__NimObject")
    System = cls"java.lang.System"
    String = cls"java.lang.String"
  if dexGlue.len == 0:
    dexGlue.add "dex.classes.add ClassDef(class: " &
      Jnim.repr & ", access: {Public}, superclass: SomeType(" & Object.repr & "),\n" &
      "  class_data: ClassData(\n" &
      "    direct_methods: @[\n" &
      "      EncodedMethod(\n" &
      "        m: Method(class: " & Jnim.repr & ", name: \"<clinit>\", prototype: Prototype(ret: \"V\")),\n" &
      "        access: {Static, Constructor},\n" &
      "        code: SomeCode(Code(\n" &
      "          registers: 2, ins: 0, outs: 1, instrs: @[\n" &
      "          # System.loadLibrary(libname)\n" &
      "          const_string(0, libname),\n" &
      "          invoke_static(0, \n" &
      "            Method(class: " & System.repr & ", name: \"loadLibrary\", prototype: Prototype(ret: \"V\", params: @[" & String.repr & "]))),\n" &
      "          return_void(),\n" &
      "          ]))\n" &
      "      )\n" &
      "    ]))\n"
    dexGlue.add "dex.classes.add ClassDef(class: " &
      NimObject.repr & ", access: {Public, Interface}, superclass: SomeType(" & Object.repr & "))\n"

  let
    class = cls(JnimPackageName & ".Jnim$" & className)
    super = if parentClass.len != 0: cls(parentClass) else: Object
    field = "Field(class: " & class.repr & ", typ: \"J\", name: " & PointerFieldName.repr & ")"
    Throws = cls"dalvik.annotation.Throws"
    Throwable = cls"java.lang.Throwable"
  dexGlue.add "dex.classes.add ClassDef(\n" &
    "  class: " & class.repr & ",\n" &
    "  access: {Public, Static},\n" &
    "  superclass: SomeType(" & super.repr & "),\n" &
    "  interfaces: @" & (NimObject & interfaces.map(cls)).repr & ",\n" &
    "  class_data: ClassData(\n" &
    "    instance_fields: @[\n" &
          # private long PointerFieldName;
    "      EncodedField(f: " & field & ", access: {Private})],\n" &
    "    direct_methods: @[\n" &
    "      EncodedMethod(\n" &
    "        m: Method(class: " & class.repr & ", name: \"<clinit>\", prototype: Prototype(ret: \"V\")),\n" &
    "        access: {Static, Constructor},\n" &
    "        code: SomeCode(Code(\n" &
    "          registers: 2, ins: 0, outs: 1, instrs: @[\n" &
    "          # System.loadLibrary(libname)\n" &
    "          const_string(0, libname),\n" &
    "          invoke_static(0, \n" &
    "            Method(class: " & System.repr & ", name: \"loadLibrary\", prototype: Prototype(ret: \"V\", params: @[" & String.repr & "]))),\n" &
    "          return_void(),\n" &
    "          ]))\n" &
    "      ),\n" &
    "      EncodedMethod(\n" &
    "        m: Method(class: " & class.repr & ", name: \"" & FinalizerName & "\", prototype: Prototype(ret: \"V\", params: @[\"J\"])),\n" &
    "        access: {Static, Public, Native},\n" &
    "        code: NoCode()\n" &
    "      ),\n" &
          # private native void `InitializerName`();
    "      EncodedMethod(\n" &
    "        m: Method(class: " & class.repr & ", name: \"" & InitializerName & "\", prototype: Prototype(ret: \"V\", params: @[])),\n" &
    "        access: {Private, Native},\n" &
    "        code: NoCode()\n" &
    "      ),\n" &
    "    ],\n" &
    "    virtual_methods: @[\n" &
          # protected void finalize() throws Throwable { super.finalize(); FinalizerName(PointerFieldName); PointerFieldName = 0; }
    "      EncodedMethod(\n" &
    "        m: Method(class: " & class.repr & ", name: \"finalize\", prototype: Prototype(ret: \"V\")),\n" &
    "        access: {Public},\n" &
    "        annotations: @[\n" &
    "          (VisSystem, EncodedAnnotation(typ: " & Throws.repr & ", elems: @[\n" &
    "            AnnotationElement(name: \"value\", value: EVArray(@[\n" &
    "              EVType(" & Throwable.repr & "),\n" &
    "            ]))\n" &
    "          ]))],\n" &
    "        code: SomeCode(Code(\n" &
    "          registers: 3, ins: 1, outs: 2, instrs: @[\n" &
                # ins: this
                # super.finalize()
    "            invoke_super(2,\n" &
    "              Method(class: " & super.repr & ", name: \"finalize\", prototype: Prototype(ret: \"V\"))),\n" &
                # this.FinalizerName(PointerFieldName)
    "            iget_wide(0, 2, " & field & "),\n" &
    "            invoke_static(0, 1,\n" &
    "              Method(class: " & class.repr & ", name: " & FinalizerName.repr & ", prototype: Prototype(ret: \"V\", params: @[\"J\"]))),\n" &
                # this.PointerFieldName = 0
    "            const_wide_16(0, 0'i16),\n" &
    "            iput_wide(0, 2, " & field & "),\n" &
    "            return_void(),\n" &
    "        ]))),\n" &
    "      ],\n" &
    "  ))\n"

  func typ(javaType: string): Type =
    case javaType
    of "void": "V"
    of "boolean": "Z"
    of "byte": "B"
    of "char": "C"
    of "int": "I"
    of "long": "J"
    of "float": "F"
    of "double": "D"
    of "short": "S"
    of "String": cls"java.lang.String"  # TODO: do we need this, or we already get java.lang.String?
    of "Object": cls"java.lang.Object"
    of "Class": cls"java.lang.Class"
    of "Throwable": cls"java.lang.Throwable"
    else: cls(javaType)

  for m in methodDefs:
    let args = m.argTypes.map(typ)
    if not m.isConstr:
      dexGlue.add "dex.classes[^1].class_data.virtual_methods.add EncodedMethod(\n" &
        "  m: Method(class: " & class.repr & ", name: " & m.name.repr & ",\n" &
        "    prototype: Prototype(ret: " & typ(m.retType).repr & ", params: @" & args.repr & ")),\n" &
        "  access: {Public, Native}, code: NoCode())\n"
    else:
      # FIXME: handle all wide types, not only "J"
      func width(typ: Type): int =
        if typ[0] in {'J'}: 2 else: 1
      let
        nregs = args.map(width).foldl(a + b, 1)  # extra 1 accounts for 'this'
        prototype = "Prototype(ret: \"V\", params: @" & args.repr & ")"
      # public `class`(`args...`) { super(`args...`); InitializerName(); }  /* a constructor */
      dexGlue.add "dex.classes[^1].class_data.direct_methods.add EncodedMethod(\n" &
        "  m: Method(class: " & class.repr & ", name: \"<init>\", prototype: " & prototype & "),\n" &
        "  access: {Public, Constructor}, code: SomeCode(Code(\n" &
        "    registers: " & nregs.repr & ".uint16, ins: " & nregs.repr & ".uint16, outs: " & nregs.repr & ".uint16, instrs: @[\n" &
        "      newDexInvoke(0x70, " & nregs.repr & ", 0, Method(class: " & super.repr & ", name: \"<init>\", prototype: " & prototype & ")),\n" &
        "      newDexInvoke(0x70, 1, 0, Method(class: " & class.repr & ", name: \"" & InitializerName & "\", prototype: Prototype(ret: \"V\", params: @[]))),\n" &
        "      return_void(),\n" &
        "    ])))\n"

macro jnimDexWrite*(genDex: static[string] = "gen_dex.nim"): untyped =
  writeFile(genDex, """
import os, strutils
import dali

if paramCount() != 2:
  stderr.write("error: bad number of arguments\n")
  stderr.write("USAGE: gen_dex CLASSES.DEX LIBFOOBAR.SO\n")
  quit(1)
var
  dexfile = paramStr(1)
  libname = paramStr(2)
libname.removePrefix("lib")
libname.removeSuffix(".so")

proc newDexInvoke(opcode: uint8, nregs, reg0: int, m: Method): Instr =
  if nregs <= 5: # Dalvik instruction format 35c
    func reg(n: int): Arg =
      if n < nregs: RegX(uint4(reg0+n)) else: RawX(0)
    newInstr(
      opcode, RawX(uint4(nregs)), reg(4),
      MethodXXXX(m),
      reg(1), reg(0), reg(3), reg(2))
  else: # Dalvik instruction format 3rc
    # FIXME: jnimGenDex support for constructors with many params not tested
    newInstr(
      opcode, RawXX(uint8(nregs)),
      MethodXXXX(m),
      RawXXXX(uint16(reg0)))

let dex = newDex()
$1
writeFile(dexfile, dex.render)
""" % [dexGlue.join("")])

macro genJexportGlue(className, parentClass: static[string], interfaces: static[seq[string]], isPublic: static[bool], methodDefs: static[seq[MethodDescr]], staticSection, emitSection: static[string]): untyped =
  # echo treeRepr(a)
  when defined(jnimGenDex):
    genDexGlue(className, parentClass, interfaces, isPublic, methodDefs, staticSection, emitSection)
  else:
    genJavaGlue(className, parentClass, interfaces, isPublic, methodDefs, staticSection, emitSection)

proc varargsToSeqStr(args: varargs[string]): seq[string] {.compileTime.} = @args
proc varargsToSeqMethodDef(args: varargs[MethodDescr]): seq[MethodDescr] {.compileTime.} = @args

proc jniFqcn*(T: type[void]): string = "void"
proc jniFqcn*(T: type[jint]): string = "int"
proc jniFqcn*(T: type[jlong]): string = "long"
proc jniFqcn*(T: type[jfloat]): string = "float"
proc jniFqcn*(T: type[jdouble]): string = "double"
proc jniFqcn*(T: type[jboolean]): string = "boolean"
proc jniFqcn*(T: type[string]): string = "String"

template nimTypeToJNIType(T: type[int32]): type = jint
template nimTypeToJNIType(T: type[int64]): type = jlong
template nimTypeToJNIType(T: type[JVMObject]): type = jobject
template nimTypeToJNIType(T: type[string]): type = jstring


template jniValueToNim(e: JNIEnvPtr, v: jint, T: type[int32]): int32 = int32(v)
template jniValueToNim(e: JNIEnvPtr, v: jstring, T: type[string]): string = $v
template jniValueToNim(e: JNIEnvPtr, v: jobject, T: type[JVMObject]): auto =
  jniObjectToNimObj(e, v, T)


template nimValueToJni(e: JNIEnvPtr, v: int32, T: type[jint]): jint = jint(v)
template nimValueToJni(e: JNIEnvPtr, v: int64, T: type[jlong]): jlong = jlong(v)
template nimValueToJni(e: JNIEnvPtr, v: string, T: type[jstring]): jstring = e.NewStringUTF(e, v)
template nimValueToJni[T](e: JNIEnvPtr, v: T, V: type[void]) = v


template jniObjectToNimObj*(e: JNIEnvPtr, v: jobject, T: type[JVMObject]): auto =
  T.fromJObject(v)

template constSig(args: varargs[string]): cstring = static(cstring(args.join()))

proc raiseJVMException(e: JNIEnvPtr) {.noreturn.} =
  checkJVMException(e) # This should raise
  doAssert(false, "unreachable")

proc getNimObjectFromJObject(e: JNIEnvPtr, j: jobject): JVMObject =
  let clazz = e.GetObjectClass(e, j)
  if unlikely clazz.isNil: raiseJVMException(e)
  let fid = e.GetFieldID(e, clazz, PointerFieldName, "J")
  if unlikely fid.isNil: raiseJVMException(e)

  e.deleteLocalRef(clazz)
  result = cast[JVMObject](e.GetLongField(e, j, fid))

proc getNimDataFromJObject(e: JNIEnvPtr, j: jobject): RootRef =
  let clazz = e.GetObjectClass(e, j)
  if unlikely clazz.isNil: raiseJVMException(e)
  let fid = e.GetFieldID(e, clazz, PointerFieldName, "J")
  if unlikely fid.isNil: raiseJVMException(e)

  e.deleteLocalRef(clazz)
  result = cast[RootRef](e.GetLongField(e, j, fid))

proc setNimDataToJObject(e: JNIEnvPtr, j: jobject, clazz: JClass, o: RootRef) =
  let fid = e.GetFieldID(e, clazz, PointerFieldName, "J")
  if unlikely fid.isNil: raiseJVMException(e)
  GC_ref(o)
  e.SetLongField(e, j, fid, cast[jlong](o))

proc finalizeJobject(e: JNIEnvPtr, j: jobject, p: jlong) =
  let p = cast[RootRef](p)
  if not p.isNil:
    GC_unref(p)

proc implementConstructor(p: NimNode, className: string, sig: NimNode): NimNode =
  let iClazz = ident"clazz"
  let classIdent = ident(className)
  result = p
  p.params[0] = classIdent # Set result type to className
  p.params.insert(1, newIdentDefs(ident"this", newTree(nnkBracketExpr, ident"typedesc", classIdent))) # First arg needs to be typedesc[className]

  var args = newTree(nnkBracket)
  for identDef in p.params[2..^1]:
    for name in identDef[0..^3]:  # [name1, ..., type, defaultValue]
      args.add(newCall("toJValue", name))

  p.body = quote do:
    const fq = JnimPackageName.replace(".", "/") & "/Jnim$" & `className`
    var `iClazz` {.global.}: JVMClass
    if unlikely `iClazz`.isNil:
      `iClazz` = JVMClass.getByFqcn(fq)
      jniRegisterNativeMethods(`classIdent`, `iClazz`)

    let inst = `iClazz`.newObjectRaw(`sig`, `args`)
    result = `classIdent`.fromJObjectConsumingLocalRef(inst)
    when compiles(result.data):
      result.data = cast[type(result.data)](getNimDataFromJObject(theEnv, inst))

macro jexport*(a: varargs[untyped]): untyped =
  var (className, parentClass, interfaces, body, isPublic) = extractArguments(a)
  let classNameIdent = newIdentNode(className)

  let nonVirtualClassNameIdent = ident("JnimNonVirtual_" & className)

  let constructors = newNimNode(nnkStmtList)

  result = newNimNode(nnkStmtList)
  result.add quote do:

    proc jniFqcn*(t: type[`classNameIdent`]): string = "Jnim." & `className`

    proc jniObjectToNimObj*(e: JNIEnvPtr, v: jobject, T: typedesc[`classNameIdent`]): `classNameIdent` =
      result = T.fromJObject(v)
      when compiles(result.data):
        result.data = cast[type(result.data)](getNimDataFromJObject(e, v))

  var parentFq: NimNode
  if parentClass.len != 0:
    parentFq = newCall("jniFqcn", newIdentNode(parentClass))
    let nonVirtualParentClassNameIdent = ident("JnimNonVirtual_" & parentClass)
    result.add quote do:
      type `nonVirtualClassNameIdent` {.used.} = object of `nonVirtualParentClassNameIdent`
  else:
    parentFq = newLit("")
    result.add quote do:
      type `nonVirtualClassNameIdent` {.used.} = object of JnimNonVirtual_JVMObject

  result.add quote do:
    proc super*(v: `classNameIdent`): `nonVirtualClassNameIdent` =
      assert(not v.getNoCreate.isNil)
      `nonVirtualClassNameIdent`(obj: v.getNoCreate)

  var inter = newCall(bindSym"varargsToSeqStr")
  for i in interfaces:
    inter.add(newCall("jniFqcn", newIdentNode(i)))

  var nativeMethodDefs = newNimNode(nnkBracket)

  var staticSection = newLit("")
  var emitSection = newLit("")

  var methodDefs = newCall(bindSym"varargsToSeqMethodDef")
  for m in body:
    case m.kind
    of nnkDiscardStmt: discard
    of nnkProcDef:
      let name = $m.name
      let isConstr = name == "new"

      let params = m.params

      var thunkParams = newSeq[NimNode]()
      # let thunkName = genSym(nskProc, JniExportedFunctionPrefix & className & "_" & $m.name)
      let thunkName = ident(JniExportedFunctionPrefix & className & "_" & $m.name)
      var thunkCall = newCall(m.name)
      let envName = newIdentNode("jniEnv")

      # Prepare for jexportAux call
      var retType: NimNode
      if params[0].kind == nnkEmpty:
        retType = newLit("void")
        thunkParams.add(newIdentNode("void"))
      else:
        retType = newCall("jniFqcn", params[0])
        thunkParams.add(newCall(bindSym"nimTypeToJNIType", copyNimTree(params[0])))

      thunkParams.add(newIdentDefs(envName, newIdentNode("JNIEnvPtr")))
      thunkParams.add(newIdentDefs(ident"this", ident"jobject"))

      thunkCall.add(newCall(ident"jniObjectToNimObj", envName, ident"this", newCall("type", classNameIdent)))

      var sig = newCall(bindSym"constSig")
      sig.add(newLit("("))

      let argTypes = newCall(bindSym"varargsToSeqStr")
      for i in 1 ..< params.len:
        for j in 0 .. params[i].len - 3:
          let paramName = params[i][j]
          let pt = params[i][^2]
          let thunkParamType = newCall(bindSym"nimTypeToJniType", copyNimTree(pt))
          argTypes.add(newCall("jniFqcn", pt))
          sig.add(newCall("jniSig", copyNimTree(pt)))
          thunkParams.add(newIdentDefs(copyNimTree(paramName), thunkParamType))
          thunkCall.add(newCall(bindSym"jniValueToNim", envName, copyNimTree(paramName), copyNimTree(pt)))
      let md = newCall(bindSym"initMethodDescr", newLit($m.name), retType, argTypes)
      methodDefs.add(md)

      sig.add(newLit(")"))
      if params[0].kind == nnkEmpty:
        sig.add(newLit("V"))
      else:
        sig.add(newCall("jniSig", params[0]))

      if not isConstr:
        nativeMethodDefs.add(newTree(nnkObjConstr, newIdentNode("JNINativeMethod"),
          newTree(nnkExprColonExpr, newIdentNode("name"), newLit($m.name)),
          newTree(nnkExprColonExpr, newIdentNode("signature"), sig),
          newTree(nnkExprColonExpr, newIdentNode("fnPtr"), thunkName)))

        # Emit the definition as is
        m.params.insert(1, newIdentDefs(ident"this", classNameIdent))

        result.add(m)

        thunkCall = newCall(bindSym"nimValueToJni", envName, thunkCall, copyNimTree(thunkParams[0]))

        let thunk = newProc(postfix(thunkName, "*"), thunkParams)
        thunk.addPragma(newIdentNode("cdecl"))
        thunk.addPragma(newIdentNode("dynlib"))
        thunk.addPragma(newIdentNode("exportc")) # Allow jni runtime to discover the functions
        thunk.body = quote do:
          if theEnv.isNil: theEnv = `envName`
          `thunkCall`
        result.add(thunk)
  
      else:
        # implement constructor
        constructors.add(implementConstructor(m, className, sig))


    of nnkCommand:
      case $m[0]
      of "staticSection":
        staticSection = m[1]
      of "emit":
        emitSection = m[1]
      else:
        echo "Unexpected AST: ", repr(m)
        assert(false)

    else:
      echo "Unexpected AST: ", repr(m)
      assert(false)

  block: # Finalizer thunk
    # let thunkName = genSym(nskProc, JniExportedFunctionPrefix & className & "__0")
    let thunkName = ident(JniExportedFunctionPrefix & className & "_" & FinalizerName.replace("_", "_1"))
    result.add quote do:
      proc `thunkName`*(jniEnv: JNIEnvPtr, this: jobject, p: jlong) {.exportc, dynlib, cdecl.} =
        finalizeJobject(jniEnv, this, p)


  result.add newCall(bindSym"genJexportGlue", newLit(className), parentFq, inter, newLit(isPublic), methodDefs, staticSection, emitSection)

  # Add finalizer impl
  # nativeMethodDefs.add(newTree(nnkObjConstr, newIdentNode("JNINativeMethod"),
  #   newTree(nnkExprColonExpr, newIdentNode("name"), newLit(FinalizerName)),
  #   newTree(nnkExprColonExpr, newIdentNode("signature"), newLit("(J)V")),
  #   newTree(nnkExprColonExpr, newIdentNode("fnPtr"), bindSym"finalizeJobject")))

  let clazzIdent = ident"clazz"
  var nativeMethodsRegistration = newEmptyNode()
  if nativeMethodDefs.len != 0:
    nativeMethodsRegistration = quote do:
      var nativeMethods = `nativeMethodDefs`
      if nativeMethods.len != 0:
        let r = callVM theEnv.RegisterNatives(theEnv, `clazzIdent`.get(), addr nativeMethods[0], nativeMethods.len.jint)
        assert(r == 0)

  result.add quote do:
    proc jniRegisterNativeMethods(t: type[`classNameIdent`], `clazzIdent`: JVMClass) =
      `nativeMethodsRegistration`

  block: # Initializer thunk
    let iClazz = ident"clazz"
    let classIdent = ident(className)
    let thunkName = ident(JniExportedFunctionPrefix & className & "_" & InitializerName.replace("_", "_1"))
    result.add quote do:
      proc `thunkName`*(jniEnv: JNIEnvPtr, this: jobject) {.exportc, dynlib, cdecl.} =
        const fq = JnimPackageName.replace(".", "/") & "/Jnim$" & `className`
        var `iClazz` {.global.}: JVMClass
        if unlikely `iClazz`.isNil:
          `iClazz` = JVMClass.getByFqcn(fq)
          # FIXME: don't repeat this here and in implementConstructor
          jniRegisterNativeMethods(`classIdent`, `iClazz`)
        when compiles(`classIdent`.data):
          let data = new(type(`classIdent`.data))
          setNimDataToJObject(theEnv, this, `iClazz`.get, cast[RootRef](data))

  result.add(constructors)

  # Generate interface converters
  for interf in interfaces:
    let converterName = newIdentNode("to" & interf)
    let interfaceName = newIdentNode(interf)
    result.add quote do:
      converter `converterName`*(v: `classNameIdent`): `interfaceName` {.inline.} =
        cast[`interfaceName`](v)

  echo repr result

macro debugPrintJavaGlue*(): untyped {.deprecated.} =
  echo javaGlue

