//
//  RemoteDebugging.swift
//  Recordings
//
//  Created by Chris Eidhof on 24.05.18.
//

import UIKit

extension UIView {
	func capture() -> UIImage? {
		let format = UIGraphicsImageRendererFormat()
		format.opaque = isOpaque
		let renderer = UIGraphicsImageRenderer(size: frame.size, format: format)
		return renderer.image { _ in
			drawHierarchy(in: frame, afterScreenUpdates: true)
		}
	}
}

struct DebugData<S: Encodable>: Encodable {
	var state: S
	var action: String
	var imageData: Data
}

final class Reader: NSObject, StreamDelegate {
	private let input: InputStream
	private let queue = DispatchQueue(label: "remote debugger reader")
	private let onResult: (Result) -> ()
	
	enum Result {
		case eof
		case error(Error)
		case chunk(Data)
	}
	
	init(_ inputStream: InputStream, onResult: @escaping (Result) -> ()) {
		self.input = inputStream
		self.onResult = onResult
		super.init()
		CFReadStreamSetDispatchQueue(inputStream, queue)
		inputStream.open()
		inputStream.delegate = self
	}
	
	func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
		switch eventCode {
		case .openCompleted:
			()
		case .hasBytesAvailable:
			// todo read
			let chunkSize = 1024
			var data = Data(count: chunkSize)
			let bytesRead = data.withUnsafeMutableBytes { bytes in
				input.read(bytes, maxLength: chunkSize)
			}
			switch bytesRead {
			case -1:
				input.close()
				onResult(.error(input.streamError!))
			case 0:
				input.close()
				onResult(.eof)
			case 1...:
				onResult(.chunk(data.prefix(bytesRead)))
			default:
				fatalError()

			}
		case .errorOccurred:
			input.close()
			onResult(.error(input.streamError!))
		case .endEncountered:
			input.close()
			onResult(.eof)
		default:
			fatalError("Unknown event \(eventCode)")
		}
	}
}


final class BufferedWriter: NSObject, StreamDelegate {
	private let output: OutputStream
	private let queue = DispatchQueue(label: "remote debugger writer")
	private var buffer = Data()
	private let onEnd: (Result) -> ()
	
	enum Result {
		case eof
		case error(Error)
	}
	
	init(_ outputStream: OutputStream, onEnd: @escaping (Result) -> ()) {
		self.output = outputStream
		self.onEnd = onEnd
		super.init()
		CFWriteStreamSetDispatchQueue(outputStream, queue)
		outputStream.open()
		outputStream.delegate = self
	}
	
	func write(_ data: Data) {
		queue.async {
			self.buffer.append(data)
			self.resume()
		}
	}
	
	private func resume() {
		while output.hasSpaceAvailable && output.streamStatus == .open && !buffer.isEmpty {
			let data = buffer.prefix(1024)
			let bytesWritten = data.withUnsafeBytes { bytes in
				output.write(bytes, maxLength: data.count)
			}
			switch bytesWritten {
			case -1:
				output.close()
				onEnd(.error(output.streamError!))
			case 0:
				output.close()
				onEnd(.eof)
			case 1...:
				buffer.removeFirst(bytesWritten)
			default:
				fatalError()
			}
		}
	}
	
	func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
		switch eventCode {
		case .openCompleted:
			resume()
		case .hasSpaceAvailable:
			resume()
		case .errorOccurred:
			output.close()
			onEnd(.error(output.streamError!))
		case .endEncountered:
			output.close()
			onEnd(.eof)
		default:
			fatalError("Unknown event \(eventCode)")

		}
	}
}

struct JSONOverTCPDecoder<S: Decodable> {
	private let onResult: (S?) -> ()
	private var buffer = Data()
	private var bytesExpected: Int?
	
	init(_ onResult: @escaping (S?) -> ()) {
		self.onResult = onResult
	}
	
	mutating func decode(_ data: Data) {
		buffer.append(data)
		// todo wrap in loop
		if buffer.count > 5 && bytesExpected == nil {
			guard buffer.removeFirst() == 206 else {
				onResult(nil) // error
				return
			}
			let sizeData = buffer.prefix(4)
			buffer.removeFirst(4)
			assert(sizeData.count == 4)
			let count: Int32 = sizeData.withUnsafeBytes { $0.pointee }
			bytesExpected = Int(count)
		}
		if let b = bytesExpected, buffer.count >= b {
			let jsonData = buffer.prefix(b)
			buffer.removeFirst(b)
			let decoder = JSONDecoder()
			let result = try? decoder.decode(S.self, from: jsonData)
			onResult(result)
		}
	}
}

final class RemoteDebugger<State: Codable>: NSObject, NetServiceBrowserDelegate {
	let browser = NetServiceBrowser()
	let queue = DispatchQueue(label: "remoteDebugger")
	var writer: BufferedWriter?
	var reader: Reader?
	var onReceive: ((State) -> ())?
	
	override init() {
		super.init()
		browser.delegate = self
		browser.searchForServices(ofType: "_debug._tcp", inDomain: "local")
	}
	
	func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
		var input: InputStream?
		var output: OutputStream?
		service.getInputStream(&input, outputStream: &output)
		CFReadStreamSetDispatchQueue(input, queue)
		if let o = output {
			writer = BufferedWriter(o) { [unowned self] result in
				print(result)
				self.writer = nil
			}
		}
		
		if let i = input {
			var decoder = JSONOverTCPDecoder<State> { result in
				if let r = result {
					self.onReceive?(r)
				} else {
					print("Decoding error")
				}
			}
			reader = Reader(i) { result in
				switch result {
				case .chunk(let data): decoder.decode(data)
				default: () // todo
				}
			}
		}
	}
	
	func write(action: String, state: State, snapshot: UIView) throws {
		guard let w = writer else { return }
		
		let image = snapshot.capture()!
		let imageData = UIImagePNGRepresentation(image)!
		let data = DebugData(state: state, action: action, imageData: imageData)
		let encoder = JSONEncoder()
		let json = try! encoder.encode(data)
		var encodedLength = Data(count: 4)
		encodedLength.withUnsafeMutableBytes { bytes in
			bytes.pointee = Int32(json.count)
		}
		w.write([206] + encodedLength + json)
	}
}
