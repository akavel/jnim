
when defined jnimGenDex:
  import ../jnim/private / [ jni_api, jni_generator, jni_export ],
         ./common,
         unittest

  echo "hello jniExport"

  jclass io.github.yglukhov.jnim.ExportTestClass$Interface of JVMObject:
    proc voidMethod()
    proc intMethod*(): jint # Test public
    proc stringMethod(): string
    proc stringMethodWithArgs(s: string, i: jint): string

  jclass io.github.yglukhov.jnim.ExportTestClass$Tester of JVMObject:
    proc new
    proc callVoidMethod(r: Interface)
    proc callIntMethod(r: Interface): jint
    proc callStringMethod(r: Interface): string
    proc callStringMethodWithArgs(r: Interface, s: string, i: jint): string

  jclass io.github.yglukhov.jnim.ExportTestClass$Implementation of Interface:
    proc new

  type
    MyObjData = ref object
      a: int

    MyObj = ref object of JVMObject
      data: MyObjData

    MyObjSub = ref object of MyObj
    ImplementationSub = ref object of Implementation

  jexport MyObj implements Interface:
    proc new() = super()

    proc voidMethod() # Test fwd declaration

    proc intMethod*(): jint = # Test public
      return 123

    proc stringMethod(): string =
      return "Hello world"

    proc stringMethodWithArgs(s: string, i: jint): string =
      return "123" & $i & s

  jexport MyObjSub extends MyObj:
    proc new = super()

    proc stringMethod(): string =
      "Nim"

  jexport ImplementationSub extends Implementation:
    proc new() = super()

    proc stringMethod(): string =
      this.super.stringMethod() & " is awesome"

  proc voidMethod(this: MyObj) =
    inc this.data.a

  jnimDexWrite("tmp.nim", "classes.dex", "libfoo.so")
