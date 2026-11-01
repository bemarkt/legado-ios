// swift-tools-version: 6.0
import PackageDescription

// Vendored quickjs-ng (commit 7b5f588e0f9b643e2996f291bfc861abeaceddc2, QJS 0.17.0).
// Only the interpreter sources are shipped: qjs.c / qjsc.c / quickjs-libc.c (POSIX
// libc bindings) and the generators are intentionally excluded, because they need
// unistd/pthread and are never used by a sandboxed rule engine.
//
// No unsafeFlags: a package that uses them cannot be depended upon by another
// package, which would break both the root Package.swift and the Xcode local
// package reference.
let package = Package(
    name: "QuickJS",
    platforms: [
        .iOS(.v15),
        .macOS(.v14)
    ],
    products: [
        .library(name: "CQuickJS", targets: ["CQuickJS"])
    ],
    targets: [
        .target(
            name: "CQuickJS",
            path: "Sources/CQuickJS",
            publicHeadersPath: "include"
        )
    ]
)
