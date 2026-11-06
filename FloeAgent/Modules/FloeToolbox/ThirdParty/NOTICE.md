# Third-party source references

USBSerialPlans.swift adapts chip request/baud/status algorithms from:

- mik3y/usb-serial-for-android, commit 4cb9e82cdcfa095eb2fe0b0bea9605f50bd8e2f2.
- Files: CdcAcmSerialDriver.java, FtdiSerialDriver.java, Cp21xxSerialDriver.java, Ch34xSerialDriver.java, ProlificSerialDriver.java.
- Per-file copyright notices: Copyright 2011-2013 Google Inc.; Copyright 2013 mike wakerly <opensource@hoho.com>; Copyright 2014 Andreas Butti; Copyright 2020 kai morich <mail@kai-morich.de> (FTDI).
- MIT license, included in LICENSE.usb-serial-for-android.txt.
- ProlificSerialDriver.java credits the Android port to Felix Hädicke, based on Emmanuel Blot's pyprolific work; these source attributions are retained here.

The Android platform code is not linked. USBSerialBackend.cpp is an original public-USBDriverKit backend; the RTL-SDR project was examined as an architectural reference and no RTL-SDR driver, tuner, audio keep-alive or entitlement file is bundled.

Root repository licensing applies to original Floe source. Actual USB hardware compatibility, distribution entitlements and the eventual signed DriverKit extension are separate from these source references and object compilations.
