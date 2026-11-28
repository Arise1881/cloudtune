import 'dart:ffi' as ffi;

String currentAndroidAbi() => switch (ffi.Abi.current()) {
      ffi.Abi.androidArm64 => 'androidArm64',
      ffi.Abi.androidArm => 'androidArm',
      ffi.Abi.androidX64 => 'androidX64',
      ffi.Abi.androidIA32 => 'androidIA32',
      _ => 'unknown',
    };
