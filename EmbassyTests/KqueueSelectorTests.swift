//
//  KqueueSelectorTests.swift
//  Embassy
//
//  Created by Fang-Pen Lin on 5/20/16.
//  Copyright © 2016 Fang-Pen Lin. All rights reserved.
//

import XCTest

@testable import Embassy

struct FileDescriptorEvent {
    let fileDescriptor: Int32
    let ioEvent: IOEvent
}

extension FileDescriptorEvent: Equatable {
}

func ==(lhs: FileDescriptorEvent, rhs: FileDescriptorEvent) -> Bool {
    return lhs.fileDescriptor == rhs.fileDescriptor && lhs.ioEvent == rhs.ioEvent
}
    
extension FileDescriptorEvent: Hashable {
    var hashValue: Int {
        return fileDescriptor.hashValue + ioEvent.hashValue
    }
}

class KqueueSelectorTests: XCTestCase {
    let queue = dispatch_queue_create("com.envoy.embassy-tests.kqueue", DISPATCH_QUEUE_SERIAL)
    
    func testRegister() {
        let selector = try! KqueueSelector()
        let socket = try! TCPSocket()
        
        XCTAssertNil(selector[socket.fileDescriptor])
        
        let data = "my data"
        try! selector.register(socket.fileDescriptor, events: Set<IOEvent>([.Read]), data: data)
        
        let key = selector[socket.fileDescriptor]
        XCTAssertEqual(key?.fileDescriptor, socket.fileDescriptor)
        XCTAssertEqual(key?.events, Set<IOEvent>([.Read]))
        XCTAssertEqual(key?.data as? String, data)
    }

    func testUnregister() {
        let selector = try! KqueueSelector()
        let socket = try! TCPSocket()
        
        try! selector.register(socket.fileDescriptor, events: Set<IOEvent>([.Read]), data: nil)
        
        try! selector.unregister(socket.fileDescriptor)
        XCTAssertNil(selector[socket.fileDescriptor])
    }
    
    func testSelectOneSocket() {
        let selector = try! KqueueSelector()
        
        let port = try! getUnusedTCPPort()
        let listenSocket = try! TCPSocket()
        listenSocket.blocking = false
        try! listenSocket.bind(port)
        try! listenSocket.listen()
        
        try! selector.register(listenSocket.fileDescriptor, events: Set<IOEvent>([.Read]), data: nil)
        
        // ensure we have a correct timeout here
        assertExecutingTime(2, accuracy: 1) {
            XCTAssertEqual(try! selector.select(2.0).count, 0)
        }
        
        let clientSocket = try! TCPSocket()
        
        // make a connect 1 seconds later
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, Int64(1 * NSEC_PER_SEC)), queue) {
            try! clientSocket.connect("::1", port: port)
        }
        
        let ioEvents = assertExecutingTime(1, accuracy: 1) {
            return try! selector.select(10.0)
        }
        XCTAssertEqual(ioEvents.count, 1)
        XCTAssertEqual(ioEvents.first?.0.fileDescriptor, listenSocket.fileDescriptor)
        XCTAssertEqual(ioEvents.first?.0.events, Set<IOEvent>([.Read]))
        XCTAssertNil(ioEvents.first?.0.data)
    }
    
    func testSelectEventFilter() {
        let selector = try! KqueueSelector()
        
        let port = try! getUnusedTCPPort()
        let listenSocket = try! TCPSocket()
        listenSocket.blocking = false
        try! listenSocket.bind(port)
        try! listenSocket.listen()
        
        try! selector.register(listenSocket.fileDescriptor, events: Set<IOEvent>([.Write]), data: nil)
        
        XCTAssertEqual(try! selector.select(1.0).count, 0)
        
        let clientSocket = try! TCPSocket()
        // make a connect 1 seconds later
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, Int64(1 * NSEC_PER_SEC)), queue) {
            try! clientSocket.connect("::1", port: port)
        }
        
        // ensure we don't get any event triggered in two seconds
        XCTAssertEqual(try! selector.select(2.0).count, 0)
    }
    
    func testSelectAfterUnregister() {
        let selector = try! KqueueSelector()
        
        let port = try! getUnusedTCPPort()
        let listenSocket = try! TCPSocket()
        listenSocket.blocking = false
        try! listenSocket.bind(port)
        try! listenSocket.listen()
        
        try! selector.register(listenSocket.fileDescriptor, events: Set<IOEvent>([.Read]), data: nil)
        
        let clientSocket = try! TCPSocket()
        // make a connect 1 seconds later
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, Int64(1 * NSEC_PER_SEC)), queue) {
            try! clientSocket.connect("::1", port: port)
        }
        
        assertExecutingTime(1, accuracy: 1) {
            let events = try! selector.select(2.0)
            let result = toEventSet(events)
            XCTAssertEqual(result, Set([
                FileDescriptorEvent(fileDescriptor: listenSocket.fileDescriptor, ioEvent: .Read),
            ]))
        }
        
        try! selector.unregister(listenSocket.fileDescriptor)
        
        let clientSocket2 = try! TCPSocket()
        // make a connect 1 seconds later
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, Int64(1 * NSEC_PER_SEC)), queue) {
            try! clientSocket2.connect("::1", port: port)
        }
        
        assertExecutingTime(2, accuracy: 1) {
            XCTAssertEqual(try! selector.select(2.0).count, 0)
        }
    }
    
    func testSelectMultipleSocket() {
        let selector = try! KqueueSelector()
        
        let port = try! getUnusedTCPPort()

        let clientSocket = try! TCPSocket()
        clientSocket.blocking = false
        
        let listenSocket = try! TCPSocket()
        listenSocket.blocking = false
        try! listenSocket.bind(port)
        try! listenSocket.listen()
        
        try! selector.register(listenSocket.fileDescriptor, events: Set<IOEvent>([.Read, .Write]), data: nil)
        try! selector.register(clientSocket.fileDescriptor, events: Set<IOEvent>([.Read, .Write]), data: nil)
        
        try! clientSocket.connect("::1", port: port)
        
        sleep(1)
        
        let ioEvents0 = assertExecutingTime(0, accuracy: 1) {
            return try! selector.select(10.0)
        }
        let result0 = toEventSet(ioEvents0)
        XCTAssertEqual(result0, Set([
            FileDescriptorEvent(fileDescriptor: clientSocket.fileDescriptor, ioEvent: .Write),
            FileDescriptorEvent(fileDescriptor: listenSocket.fileDescriptor, ioEvent: .Read),
        ]))
        
        let acceptedSocket = try! listenSocket.accept()
        acceptedSocket.blocking = false
        try! selector.register(acceptedSocket.fileDescriptor, events: Set<IOEvent>([.Read, .Write]), data: nil)
        
        let ioEvents1 = assertExecutingTime(0, accuracy: 1) {
            return try! selector.select(10.0)
        }
        let result1 = toEventSet(ioEvents1)
        XCTAssertEqual(result1, Set([
            FileDescriptorEvent(fileDescriptor: clientSocket.fileDescriptor, ioEvent: .Write),
            FileDescriptorEvent(fileDescriptor: acceptedSocket.fileDescriptor, ioEvent: .Write),
        ]))
        
        // we should have no events now
        assertExecutingTime(1, accuracy: 1) {
            return try! selector.select(1)
        }
        
        try! clientSocket.send(Array("hello".utf8))
        
        let ioEvents2 = assertExecutingTime(0, accuracy: 1) {
            return try! selector.select(10.0)
        }
        let result2 = toEventSet(ioEvents2)
        XCTAssertEqual(result2, Set([
            FileDescriptorEvent(fileDescriptor: clientSocket.fileDescriptor, ioEvent: .Write),
            FileDescriptorEvent(fileDescriptor: acceptedSocket.fileDescriptor, ioEvent: .Read),
            FileDescriptorEvent(fileDescriptor: acceptedSocket.fileDescriptor, ioEvent: .Write)
        ]))
        
        let receivedString = String(bytes: try! acceptedSocket.recv(1024), encoding: NSUTF8StringEncoding)
        XCTAssertEqual(receivedString, "hello")
        
        let ioEvents3 = assertExecutingTime(0, accuracy: 1) {
            return try! selector.select(10.0)
        }
        let result3 = toEventSet(ioEvents3)
        XCTAssertEqual(result3, Set([
            FileDescriptorEvent(fileDescriptor: clientSocket.fileDescriptor, ioEvent: .Write),
            FileDescriptorEvent(fileDescriptor: acceptedSocket.fileDescriptor, ioEvent: .Write)
        ]))
        
        // we should have no events now
        assertExecutingTime(1, accuracy: 1) {
            return try! selector.select(1)
        }
    }
    
    private func toEventSet(events: [(SelectorKey, Set<IOEvent>)]) -> Set<FileDescriptorEvent> {
        return Set(events.flatMap { (key, ioEvents) in
            return ioEvents.map { FileDescriptorEvent(fileDescriptor: key.fileDescriptor, ioEvent: $0) }
        })
    }
    
    private func assertExecutingTime<T>(time: NSTimeInterval, accuracy: NSTimeInterval, file: StaticString = #file, line: UInt = #line, @noescape closure: Void -> T) -> T {
        let begin = NSDate()
        let result = closure()
        let elapsed = NSDate().timeIntervalSinceDate(begin)
        XCTAssertEqualWithAccuracy(elapsed, time, accuracy: accuracy, "Wrong executing time", file: file, line: line)
        return result
    }
}