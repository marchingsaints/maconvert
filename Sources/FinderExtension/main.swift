import Foundation

// App extensions start in NSExtensionMain, which Xcode normally wires up via a
// linker flag. Building without Xcode, we call it ourselves.
@_silgen_name("NSExtensionMain")
func NSExtensionMain(_ argc: Int32, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32

exit(NSExtensionMain(CommandLine.argc, CommandLine.unsafeArgv))
