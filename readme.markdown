About DTDownload
==================

DTDownload started out as a wrapper around NSURLConnection when I needed resumable file downloads for iCatalog. It has since grown into several parts. For file and image caching you can use DTDownloadCache, for queueing up a large number of downloads use DTDownloadQueue.

License
------- 
 
It is open source and covered by a standard BSD license. That means you have to mention *Cocoanetics* as the original author of this code. You can purchase a Non-Attribution-License from us.

Documentation
-------------

Documentation can be [browsed online](http://cocoanetics.github.com/DTDownload) or installed in your Xcode Organizer via the [Atom Feed URL](http://cocoanetics.github.com/DTDownload/DTDownload.atom).

Usage
-----

You have these options of including DTDownload in your project

- DTDownload on CocoaPods
- include the git repo as a submodule
- clone a copy of it into an Externals folder in your project tree

Note: DTDownload requires some elements from DTFoundation/Core

When not using CocoaPods these are the steps for setup:

- include the xcodeproj as a sub-project
- Add the ObjC and all_load linker flags
- add a dependency to the static library for your platform
- add the static library also to the linking phase
- add a User Header Search Path into the location where you have the code