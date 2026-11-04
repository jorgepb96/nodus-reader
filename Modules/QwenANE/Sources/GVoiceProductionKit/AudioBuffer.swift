import Foundation

public struct ReferenceAudioBuffer: Sendable, Equatable {
    public var sampleRate: Int
    public var channels: [[Float]]
    public init(sampleRate: Int, channels: [[Float]]) {
        self.sampleRate = sampleRate; self.channels = channels
    }
    public var frameCount: Int { channels.first?.count ?? 0 }
    public var channelCount: Int { channels.count }
    public var durationSeconds: Double { sampleRate > 0 ? Double(frameCount) / Double(sampleRate) : 0 }
}

public struct AudioProperties: Sendable, Equatable {
    public var sampleRate: Int; public var channels: Int; public var durationSeconds: Double
    public init(sampleRate: Int, channels: Int, durationSeconds: Double) {
        self.sampleRate = sampleRate; self.channels = channels; self.durationSeconds = durationSeconds
    }
}
