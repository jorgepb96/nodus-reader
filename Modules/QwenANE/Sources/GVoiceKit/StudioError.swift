/// Errors thrown by StudioKit stores. Mirrors the Python engine's exception
/// taxonomy (ValueError / FileExistsError / FileNotFoundError) so the HTTP
/// layer can map them to the same status codes.
public enum StudioError: Error, Equatable, Sendable {
    case invalidName(String)            // name produces an empty slug
    case voiceExists(slug: String)
    case voiceNotFound(slug: String)
    case invalidArchive(String)         // not a valid .gvoice
    case historyEntryNotFound(String)
    case invalidRefAudio(String)
}
