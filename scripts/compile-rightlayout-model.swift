#!/usr/bin/env swift
import CoreML
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

guard CommandLine.arguments.count == 3 else {
    fail("Использование: swift compile-rightlayout-model.swift <модель.mlmodel> <каталог.mlmodelc>")
}
let source = URL(fileURLWithPath: CommandLine.arguments[1])
let destination = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
let files = FileManager.default
guard files.fileExists(atPath: source.path) else {
    fail("Исходная модель не найдена: \(source.path)")
}
guard !files.fileExists(atPath: destination.path) else {
    fail("Целевой каталог уже существует: \(destination.path)")
}
do {
    let compiled = try MLModel.compileModel(at: source)
    defer { try? files.removeItem(at: compiled) }
    try files.copyItem(at: compiled, to: destination)
    print("RightLayout: модель скомпилирована в \(destination.path)")
} catch {
    fail("Ошибка компиляции RightLayout: \(error.localizedDescription)")
}
