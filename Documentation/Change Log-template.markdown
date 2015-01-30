Change Log
==========

This is the history of version updates.


**Version 1.1.2**

ADDED - Support for downloading first added URLs first or last added URLs first
READDED - armv7s to lib building
CHANGED - Updated DTFoundation to require 1.7.4
UPDATED - Changed the way appledoc is built

**Version 1.1.1**

- FIXED: arm64 Warnings
- FIXED: DTDownload.h could not found building via Cocoapods. Moved into new Core subspec
- FIXED: [DTDownloadCache] Error on __weak when building for platform not supporting zeroing weak refs
- CHANGED: Migrated Unit Tests to xctest
- CHANGED: Updated DTFoundation to require 1.7.x

**Version 1.1.0**

- FIXED: Error domain string
- ADDED: Download priority in DTDownloadQueue
- CHANGED: Updated DTFoundation to 1.6.2

**Version 1.0.3**

- ADDED: Ability to set headers for requests
- ADDED: Implemented Unit Testing and Coverage support
- CHANGED: Updated DTFoundation to 1.6.0
- CHANGED: Moved DTDownloadCache and DTDownloadQueue into CocoaPods subspecs

**Version 1.0.2**

- ADDED: Sample for DTDownloadCache
- FIXED: Support for web servers that don't support partial content for resuming

**Version 1.0.1**

- FIXED: Downloads would be corrupted if requesting partial file from server that didn't support that
