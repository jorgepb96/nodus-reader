// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import PhononTTS

/// One of Gradium's Phonon voices (gradium/phonon-voices, Apache-2.0).
struct PhononVoiceFile: Sendable {
    let name: String
    let file: String
    let language: String
    let bytes: Int64
    let sha256: String
}

/// Phonon 40M Spanish and Multilingual on the device. Gradium publishes these checkpoints only
/// as PyTorch weights,
/// behind a gate each person accepts on Hugging Face (CC BY-NC 4.0). Nodus Reader therefore
/// never hosts or ships it: it downloads the checkpoint with the user's own Hugging Face access,
/// checks every file against the pinned revision, adds the public Spanish voices, and exports
/// a Core ML bundle here with Gradium's exporter (built into PhononCore). The downloaded
/// weights are deleted once the bundle exists.
enum PhononOnDeviceConversion {
    struct RemoteFile: Sendable {
        let path: String
        let bytes: Int64
        let sha256: String
    }

    enum Phase: Sendable {
        case downloading(Double)
        case converting
    }

    /// One gated checkpoint, pinned, and which of Gradium's voices it is exported with.
    struct Spec: Sendable {
        let modelID: String
        let repository: String
        let revision: String
        let checkpointFiles: [RemoteFile]
        /// Voice languages to include ("es"), or nil for every voice.
        let voiceLanguages: Set<String>?

        var page: URL { URL(string: "https://huggingface.co/\(repository)")! }
        var voices: [PhononVoiceFile] {
            guard let voiceLanguages else { return PhononOnDeviceConversion.voiceCatalog }
            return PhononOnDeviceConversion.voiceCatalog.filter {
                voiceLanguages.contains(String($0.language.prefix(2)))
            }
        }
        var downloadBytes: Int64 {
            checkpointFiles.reduce(0) { $0 + $1.bytes } + voices.reduce(0) { $0 + $1.bytes }
        }
    }

    static func spec(forModelID id: String) -> Spec? {
        [spanish, multilingual].first { $0.modelID == id }
    }

    static let spanish = Spec(
        modelID: "phonon-40m-es",
        repository: "gradium/phonon-40m-es",
        revision: "f0d2f39c9b58ad4c19a189e3ba989ee4df393cc5",
        checkpointFiles: spanishCheckpoint,
        voiceLanguages: ["es"]
    )

    static let multilingual = Spec(
        modelID: "phonon-40m-multilingual",
        repository: "gradium/phonon-40m-multilingual",
        revision: "1537ce46c64f42903e0d608b132ccb073dac46d2",
        checkpointFiles: [
            RemoteFile(path: "config.json", bytes: 4_674,
                       sha256: "e312ab694d5ec1f79ccea520a2eeec989969ce07e9b4189ae7e9ad8e035ef82e"),
            RemoteFile(path: "tokenizer.json", bytes: 277_749,
                       sha256: "a5e8c6060bf927ed367314f21355148fdf4acff6fadb94e49c86bc7182449433"),
            RemoteFile(path: "model.safetensors", bytes: 121_713_400,
                       sha256: "54337d793c7e6ee231a4b24164fe23621cac06a726ddb55d57776ac0f8133210")
        ],
        voiceLanguages: nil
    )

    private static let spanishCheckpoint: [RemoteFile] = [
        RemoteFile(path: "config.json", bytes: 4_634,
                   sha256: "353a6153d9bfacdfe9bd2426e4ae1d1c055c86a17cdb172ca3eacd1dfb454a22"),
        RemoteFile(path: "tokenizer.json", bytes: 278_837,
                   sha256: "e6a00cd1a15986fa1e79ba338fa8174a2dd8c6c4630a66bf9c36237b2ebc4a15"),
        RemoteFile(path: "model.safetensors", bytes: 121_713_400,
                   sha256: "fab5eaeda2a738dfaa8559bfca045cf4bd92fbbb98b30f85315a4d08f04a5d30")
    ]

    static let voicesRepository = "gradium/phonon-voices"
    static let voicesRevision = "0ee17205f254b5abc43b266c8a0f215565c352f7"
    /// Every voice of gradium/phonon-voices at the pinned revision (Spanish, English including
    /// the character voices, French, German and Portuguese).
    static let voiceCatalog: [PhononVoiceFile] = [
        PhononVoiceFile(name: "Noa", file: "voices/b6FvJAiokjdqIti4.safetensors", language: "es-ES", bytes: 256136, sha256: "0bc37938a306a35f6c9f8ea53ccca14c5fc8b5575850f0cd15b352f4c3ce826e"),
        PhononVoiceFile(name: "Lucía-Sol", file: "voices/3p0eIGbkmny71GlA.safetensors", language: "es-ES", bytes: 256136, sha256: "275928c11b3c8b02e51c72653d060433e1d73a01458ef21b18e9a7f5cbd5205c"),
        PhononVoiceFile(name: "Candela", file: "voices/c9wqBDmQiBie5q6Y.safetensors", language: "es-ES", bytes: 256136, sha256: "4857d013c7502e4d074778b17122e85919bffa52741a0072e412dd3926853dcb"),
        PhononVoiceFile(name: "Celia", file: "voices/rmLBOdHrfkFym9MM.safetensors", language: "es-ES", bytes: 256136, sha256: "6ed37f47fe59674b0c9f2c099ab983d4a847ca14d09aedf80f1608a11148c757"),
        PhononVoiceFile(name: "Alba", file: "voices/u2UscyAnHilpiwmf.safetensors", language: "es-ES", bytes: 256136, sha256: "edd14cc89944ec7a9b1a87cc6be6f371f1a56791d344d921f850e2106e6dee9e"),
        PhononVoiceFile(name: "Alicia", file: "voices/4701YgRXjkBcg6sL.safetensors", language: "es-ES", bytes: 256136, sha256: "74c6bf732b76478e77072d21feca13b0bf0c664eccd2186902a63ba0d9effe59"),
        PhononVoiceFile(name: "Marcos", file: "voices/jvPx8j8zLGQ3utZz.safetensors", language: "es-ES", bytes: 256136, sha256: "be8c5f329070f40c39007bea13cee9503fe71599704cfe55c67d6eb51f5e6eb2"),
        PhononVoiceFile(name: "Borja", file: "voices/tIjCgP8v3RY8UpgM.safetensors", language: "es-ES", bytes: 256136, sha256: "fc8828dcdad4a09b7066b9008b108b77976ec4880d531da7761ded9a431bd208"),
        PhononVoiceFile(name: "Iker", file: "voices/t-_TS1e-0GzDAX02.safetensors", language: "es-ES", bytes: 256136, sha256: "25c6df91a261bcb96d9e5152c9b0988398859c0e6f4ee5f08dd577fd3bd0300d"),
        PhononVoiceFile(name: "Nuno", file: "voices/fghJGlv90qu8OJ36.safetensors", language: "es-ES", bytes: 256136, sha256: "60656e9cd518454850a7e6ecacb953572a4a23f0a358fe3b4fb946b67f6bf934"),
        PhononVoiceFile(name: "Izan", file: "voices/Ejb29qHnSOK0cIHY.safetensors", language: "es-ES", bytes: 256136, sha256: "471332253b2f76c406e395230453a7a737708cca18461237cfce0239430cb071"),
        PhononVoiceFile(name: "Guillermo", file: "voices/FaLVVqpFQcDOtq45.safetensors", language: "es-ES", bytes: 256136, sha256: "31a3837cc6705f37f95c27282ebeba71609b32204622245a6436258cd3d3497d"),
        PhononVoiceFile(name: "Nerea", file: "voices/EQcQFGkYfMn5YJgx.safetensors", language: "es-ES", bytes: 256136, sha256: "c419a49606182c98e06c369d0cfb9b66cc0f16bfdbc70490fa7daf2289144986"),
        PhononVoiceFile(name: "Rebeca", file: "voices/Sx8m6WdXBG06zwZT.safetensors", language: "es-MX", bytes: 256136, sha256: "8756dddf95fa449d0e5a8649c6a242a460329c53e2f870bbe6ed744d0573a251"),
        PhononVoiceFile(name: "Regina", file: "voices/s58clrg2fe0MO7Y-.safetensors", language: "es-MX", bytes: 256136, sha256: "ab923d4fd9ed09954e3a91c61780bcd536f5bb5787e1d0541cb6ff56dd7ff531"),
        PhononVoiceFile(name: "Danae", file: "voices/evfxKSxpDIhmsNoq.safetensors", language: "es-MX", bytes: 256136, sha256: "549f2a8dec851b967edbbd67b29d2da0799eec9ec2fefb5b0ec8aa99436d3eea"),
        PhononVoiceFile(name: "Azucena", file: "voices/KJpIQlbYrZPA4aLq.safetensors", language: "es-MX", bytes: 256136, sha256: "b5bcbbce39a6332b2f79067be19688753c28c1fc4053bf41fd4608d54c24e1ee"),
        PhononVoiceFile(name: "Jimena", file: "voices/qG5BXOJYrKEnXLIX.safetensors", language: "es-MX", bytes: 256136, sha256: "3d5590357dbd87b697a14573bbdc1f29e2abc5b6cd8a5e9ed3c98e325dede435"),
        PhononVoiceFile(name: "Ximena", file: "voices/VDwnGxAo68C8U8vC.safetensors", language: "es-MX", bytes: 256136, sha256: "ccb1b88e3899db1cb7ba71007d08ed56dd743882214f0495b67feab89850ffe0"),
        PhononVoiceFile(name: "Lalo", file: "voices/F05gqkzX7WhKVpSL.safetensors", language: "es-MX", bytes: 256136, sha256: "08159aad0d92cb391361abaf8c4bf6ac0d8358ab1514cce8cf5c89b448395ce5"),
        PhononVoiceFile(name: "Aldo", file: "voices/ax7dW1XB0eiMfHgO.safetensors", language: "es-MX", bytes: 256136, sha256: "128eeba9b5f5c6d336e1246ae20a40765fba8e5ac268aafa691b98bce1e0acfd"),
        PhononVoiceFile(name: "Yael", file: "voices/ALczEazoF4n6PmGl.safetensors", language: "es-MX", bytes: 256136, sha256: "f4ebe6b59ebfa09339cb4c15c9c8f0af72fb6cecd9feb1f550dee0d95c8092c1"),
        PhononVoiceFile(name: "Ulises", file: "voices/G5HLUsQd659UtRe7.safetensors", language: "es-MX", bytes: 256136, sha256: "fba1a4349c3c86aabc58d6570a82fac0ed643e5e7aa97b52a3ede6b792e6d420"),
        PhononVoiceFile(name: "Leonel", file: "voices/BkuASiOJRrJEB5qA.safetensors", language: "es-MX", bytes: 256136, sha256: "d32ad93e71b8c726a8f1aac62f276db82346fc1a74a02cfc18ce2b867cf20a07"),
        PhononVoiceFile(name: "Nico", file: "voices/PwgPEaweQILZdGc4.safetensors", language: "es-MX", bytes: 256136, sha256: "91af1c0e9233b3069fab26eabd191e6be4d7825eff5d5e1ce3034fbd8f7fcf24"),
        PhononVoiceFile(name: "Captain Silas Blackwater", file: "voices/xPDpsV3F592srkjA.safetensors", language: "en", bytes: 256136, sha256: "a09f615b0084980ebc4076d71550bf73ccd8d4df076bbbee4a9beb523a1379d9"),
        PhononVoiceFile(name: "Morwenna of the Deep", file: "voices/nOykTmcH9ydsGGIc.safetensors", language: "en", bytes: 256136, sha256: "2ff2db91e70648623df8d42c0dcd7c336b2f14cb4362d602a20f292a4d862154"),
        PhononVoiceFile(name: "Old Mortlake", file: "voices/lX3LavMNdlIbgEHH.safetensors", language: "en", bytes: 256136, sha256: "d3f9429205e5906dcd3c78edaf7c9d5148c7e389e34c82c86f72f154adb5d923"),
        PhononVoiceFile(name: "Azgorath", file: "voices/dGyGDKo2osj7h3s7.safetensors", language: "en", bytes: 256136, sha256: "83900e020c14946426614c6553c5a138ba6277e1aaa69832223bd0f0f8b73893"),
        PhononVoiceFile(name: "Fennick the Young Elf", file: "voices/cXoIXJ2llS8S0WOW.safetensors", language: "en", bytes: 256136, sha256: "a05944e4c69d61d10d66f689175ba0b081930df2d77b22f04d00ac40d3d69ecb"),
        PhononVoiceFile(name: "The Thing Under the Stairs", file: "voices/GXaSqMEmOg12OIYb.safetensors", language: "en", bytes: 256136, sha256: "bfa37bac98aefbb9de80f792c47d01a0f9e3b94e73776169040c249c8b722759"),
        PhononVoiceFile(name: "Vyrmathrax the Ancient", file: "voices/xO8xQo3BrB8FuI6J.safetensors", language: "en", bytes: 256136, sha256: "63ab4b15427844a804480a1603774262e8903dee33cb279e2749860dbfaedd10"),
        PhononVoiceFile(name: "Grub the Ogre", file: "voices/cYtsRSxV5q9IMehn.safetensors", language: "en", bytes: 256136, sha256: "b30fa847686ec1eb6be8c5bea4b6a5c5076ea66c3ff053cf98210a155d8aad1e"),
        PhononVoiceFile(name: "Master Aldric", file: "voices/gSgG5Tor0GPEnqzC.safetensors", language: "en", bytes: 256136, sha256: "a83430cc022b85c83753f859f9e44f406651646dab994fced8ef7a9a88005971"),
        PhononVoiceFile(name: "The Snow Queen", file: "voices/NIWoEurJHMJjyUTe.safetensors", language: "en", bytes: 256136, sha256: "bc8a8fcb95bb4f32d2d4376aa69d81b186b3ba2f8e9b6cb6a403b2b194590e85"),
        PhononVoiceFile(name: "Sir Bramwell", file: "voices/y2eiKxtQo2B67deU.safetensors", language: "en", bytes: 256136, sha256: "b3cea6789aeb58822af16ba08c4e5105d7febb840dcb67b47f426c19d1a8f209"),
        PhononVoiceFile(name: "Fairy Godmother", file: "voices/QXNr0SvkukLB4wPq.safetensors", language: "en", bytes: 256136, sha256: "f390c09f5e279c0f2171995a534b92f5ca5c83443906879da68fc27445f89d89"),
        PhononVoiceFile(name: "Maeve", file: "voices/6PWnV0Nq4wu7RVBT.safetensors", language: "en-GB", bytes: 256136, sha256: "56494ee67d533ad227ff0dfd0b1c13ff5aa91f1ad6e596e66c2986ba3005e844"),
        PhononVoiceFile(name: "Freya", file: "voices/GgfEkEJtxZR7gnpy.safetensors", language: "en-GB", bytes: 256136, sha256: "eb3cd47418349e618408c16bea7153988b3ad04b41a6033039dd474a9a4dcd23"),
        PhononVoiceFile(name: "Pippa", file: "voices/uem82D50GRv2Dwma.safetensors", language: "en-GB", bytes: 256136, sha256: "d41a8f01d6e33450f1ce062d332914da10beee99e585dab531750706f187c48a"),
        PhononVoiceFile(name: "Elodie-Rose", file: "voices/y9bQqIDnyxwqK01t.safetensors", language: "en-GB", bytes: 256136, sha256: "21eade9d83b2e66b9364e1b6cd999a3a6704c000a71f27f34e05ace5cdfd58bb"),
        PhononVoiceFile(name: "Imogen", file: "voices/gDT1nz7Ie36ZhL-C.safetensors", language: "en-GB", bytes: 256136, sha256: "1980ab3c35fa98a25b5f3b5e643fd852e14ca8a12a4a26b06aaf1abf2a8c68b1"),
        PhononVoiceFile(name: "Lottie", file: "voices/m9MxpY6IUGXtWp76.safetensors", language: "en-GB", bytes: 256136, sha256: "a906ebf17e43fded12b3d6bd077abb2df33bc86eff51c1beeb82e5d416527db3"),
        PhononVoiceFile(name: "Alfie", file: "voices/X6NceqF285Gr04gb.safetensors", language: "en-GB", bytes: 256136, sha256: "4de75497fff3030168e8aa6dca23ffeb332b1bc8c25d0bf3507ceadac953ae9c"),
        PhononVoiceFile(name: "Hugh", file: "voices/YyKcxPG7iIgS3jsK.safetensors", language: "en-GB", bytes: 256136, sha256: "3169d74b47a54d1eb15e4c243f56393abe9fe90c7e1c308ecf96ee67618b152a"),
        PhononVoiceFile(name: "Edwin", file: "voices/zUCxzrOrugTSis03.safetensors", language: "en-GB", bytes: 256136, sha256: "ff1d0735b8b45710462b1d1f846da040f970c6eb62c7c2f36dbfb8e5bde74f1e"),
        PhononVoiceFile(name: "Spencer", file: "voices/JOW0vchyswkQUMDS.safetensors", language: "en-GB", bytes: 256136, sha256: "cc9ac1107b0ffce282374a19beb7bfa95847724e6b7afbac991b4ae4277d5e6d"),
        PhononVoiceFile(name: "Toby", file: "voices/dME3IWyZBvmh1n1q.safetensors", language: "en-GB", bytes: 256136, sha256: "09ab315c7f4b72b4d71e66cb756184cedfb1f14d222d096e115bf95bfe7b29dc"),
        PhononVoiceFile(name: "Teddy", file: "voices/Zn7g6NxLqXlJb7Qi.safetensors", language: "en-GB", bytes: 256136, sha256: "baea0ea9506f3237a5ebfc61afb7c72dbd189c5603b199ef42fbb00dbda379e0"),
        PhononVoiceFile(name: "Bryony", file: "voices/gfP44RlHwr2kEwk7.safetensors", language: "en-GB", bytes: 256136, sha256: "bcc207a73b7885e45b49ab633d3377a10158292e3a7cef9cd6764ad107f1cb9b"),
        PhononVoiceFile(name: "Zoey", file: "voices/NbpkqMVS3CJeq2j8.safetensors", language: "en-US", bytes: 256136, sha256: "97c7f8c253413574406ab80dd23f49c3ebb2517163b00a9bf86b9c4cf43e7e23"),
        PhononVoiceFile(name: "Juniper", file: "voices/NIWIOv5vTi5eRMj8.safetensors", language: "en-US", bytes: 256136, sha256: "444378eb06b7c492b86e8fc7d13e4db1a3c0cf3e68891a960bf6f0a41a13ef35"),
        PhononVoiceFile(name: "Everly", file: "voices/vjFyp2BcCyTlUmYb.safetensors", language: "en-US", bytes: 256136, sha256: "958ea94da14f46dd48c7f64adac11ed2ad2aa45f7ccd165dfebab5272664402e"),
        PhononVoiceFile(name: "Harper", file: "voices/4SZHfMpw-p46Ywgs.safetensors", language: "en-US", bytes: 256136, sha256: "6b3da6e2d796a20c51af892c482bd6509fb88267a221aff83c870843dee2a123"),
        PhononVoiceFile(name: "Hadley", file: "voices/bXwrkHhURL1VFJdG.safetensors", language: "en-US", bytes: 256136, sha256: "a879938aa9a2df0a8220bdadef88137929f71e887bd91e7db205bd5fa11661d2"),
        PhononVoiceFile(name: "Delia", file: "voices/nGzMHMPAWGaJFHOo.safetensors", language: "en-US", bytes: 256136, sha256: "a0c3dcb91b2247eca56536be9ae8e8becc1c807b1136c5fe101552d6a155b24a"),
        PhononVoiceFile(name: "Easton", file: "voices/LMDIYE0Oa377Qh6Z.safetensors", language: "en-US", bytes: 256136, sha256: "45c582673cb20edb04ddcca2b5a8865ddfb0a82599efadb269021e87d20fbdd4"),
        PhononVoiceFile(name: "Micah", file: "voices/40QrMVgAxFiUnP9f.safetensors", language: "en-US", bytes: 256136, sha256: "0de1098d1051686a138d068e83ff09deb5053328bc74ec9541a1fdb90bfc24da"),
        PhononVoiceFile(name: "Trevor", file: "voices/0zLApsZfVLLNaEGl.safetensors", language: "en-US", bytes: 256136, sha256: "dc1341c8937af5534e6bbcc5c0fc5e7c10312229b59061228074f93683fe2261"),
        PhononVoiceFile(name: "Russell", file: "voices/_6Aslh2DxfmnRLmP.safetensors", language: "en-US", bytes: 256136, sha256: "beae9e4030efce0a935fcb0f807dc0784d598bcaa87ad4aacb047436b1eaa411"),
        PhononVoiceFile(name: "Preston", file: "voices/qIxlZ7Ei8KvWlyQH.safetensors", language: "en-US", bytes: 256136, sha256: "6e04b84d3ae8751b22bca0a4f63936f9cb648f4f2182b2d0788071ea1c0b68a1"),
        PhononVoiceFile(name: "Miles", file: "voices/d9XCyhjo4JhkHF1d.safetensors", language: "en-US", bytes: 256136, sha256: "eab20e4f159b48cfbc01b1885804e24f681f80e7a64f909182763a4e3361bee8"),
        PhononVoiceFile(name: "Noémie", file: "voices/FXxJ9mANRq6BCTX5.safetensors", language: "fr-FR", bytes: 256136, sha256: "9f575447f6908727214c2a855e0e33a7c316e9360a0d8b66c6ccaa8f6e15dade"),
        PhononVoiceFile(name: "Coralie", file: "voices/ZeSg853xFACESHHI.safetensors", language: "fr-FR", bytes: 256136, sha256: "21dd67c10f307aa48e1187f48159bb3d41b07d0cd17a3e6366efd508e6fe83a6"),
        PhononVoiceFile(name: "Tiphaine", file: "voices/0fvH6XAKvA748v2v.safetensors", language: "fr-FR", bytes: 256136, sha256: "5646677e9cf4a517e8cc316f94a34e18fa987e224925d916d6fe13396579b95b"),
        PhononVoiceFile(name: "Maëlys", file: "voices/s048cR1l2Jmu4k3B.safetensors", language: "fr-FR", bytes: 256136, sha256: "f7b80c03210e3fd736de6596586305e9b7eb0e615047dd1cbb1b58fc3f92985f"),
        PhononVoiceFile(name: "Orianne", file: "voices/TUk4X11S6UytB3G6.safetensors", language: "fr-FR", bytes: 256136, sha256: "cae40431c178258727313c8c4f7c037645ece7fc2f4287644cc7a7138ca4e90c"),
        PhononVoiceFile(name: "Solène", file: "voices/YhIHaAfQ0cQPDV9R.safetensors", language: "fr-FR", bytes: 256136, sha256: "fbed904e1c25c3410db4adc28b8e27686c9fd9d61353a02a23bcd1a6da054280"),
        PhononVoiceFile(name: "Augustin", file: "voices/Tek4tJXiX6_yvXq7.safetensors", language: "fr-FR", bytes: 256136, sha256: "0106f9a0d53685471695a76827f7912e6c890f21fea10b5e5160379da38ffe5b"),
        PhononVoiceFile(name: "Arnaud", file: "voices/aXMVwiUhITMrwPzd.safetensors", language: "fr-FR", bytes: 256136, sha256: "22421f1fbb25d325eabc351500fed2e92c53b54facc4bc97ba3bc6cc6e75e42c"),
        PhononVoiceFile(name: "Jules", file: "voices/YKeBw3OV1RgpdhLh.safetensors", language: "fr-FR", bytes: 256136, sha256: "16c1df0d46be869159d4a40c81b888eaa8dbc494045e57b24d293384149f008e"),
        PhononVoiceFile(name: "Baptiste", file: "voices/rqqeErpASHVQXHDd.safetensors", language: "fr-FR", bytes: 256136, sha256: "cce882370d25a3c4d29cb226af218a44274674805e7091447d27d3ad61bb25b3"),
        PhononVoiceFile(name: "Lucien", file: "voices/LIv4NaG8ay4Mhqtd.safetensors", language: "fr-FR", bytes: 256136, sha256: "4f7f904c976c0b493e9d42654dc81d4f9e686b986fbb3a7d511a7dcc41c7dea6"),
        PhononVoiceFile(name: "Marius", file: "voices/biuhvu17TxVKOcyy.safetensors", language: "fr-FR", bytes: 256136, sha256: "a859356200a33faf75c591d24fc0fbb998aa66b53c2120f392ef6305d824ec9d"),
        PhononVoiceFile(name: "Ninon", file: "voices/qtPlUYAZ4EJDuWMm.safetensors", language: "fr-FR", bytes: 256136, sha256: "250af13c97fdc3519ccde9c8d5e1ae1953f8ad365fc7d736aa5eae2ad2e14473"),
        PhononVoiceFile(name: "Lilou", file: "voices/4iKxBtHBRzr1YOph.safetensors", language: "fr-FR", bytes: 256136, sha256: "c93483af64a9dd990e42264d2b6bb68909fcdff66873945acf7701e501d6e849"),
        PhononVoiceFile(name: "Hélène", file: "voices/Vvakv7iWZCUrBooR.safetensors", language: "fr-FR", bytes: 256136, sha256: "a8c97074fdb4044fc8da2873bdccd8b2a64beeedab859d241d5fc11c0c400aad"),
        PhononVoiceFile(name: "Nele", file: "voices/2A2fFf8SkDEJ8nzx.safetensors", language: "de-DE", bytes: 256136, sha256: "5d5ad59fdd4642cd162f082873b27f658705a5d8598957d6274b30bf4bd4dc0b"),
        PhononVoiceFile(name: "Jette", file: "voices/4Mn9VfG2wsLLEzi5.safetensors", language: "de-DE", bytes: 256136, sha256: "720e656aa74cd81729593e0672a6213f5f9e5480bead08321e2a6a327eb8e453"),
        PhononVoiceFile(name: "Annika", file: "voices/p6Uutkyi3j2iNAUu.safetensors", language: "de-DE", bytes: 256136, sha256: "0a4ec738c4222645f175dca1015686b0a628f100650a5e0ab26e88d0a9b60fd4"),
        PhononVoiceFile(name: "Jule", file: "voices/MxhgvuHuUER7qjmL.safetensors", language: "de-DE", bytes: 256136, sha256: "05160ccf33ce0e22da9a2eb601e992bc9fc34e2591e22d3af4f07a07f3731cb7"),
        PhononVoiceFile(name: "Lotta", file: "voices/MOrDPn052KUlnKXk.safetensors", language: "de-DE", bytes: 256136, sha256: "a0f55b29cf02a7bab15a9f8ff961f632e7f7a393b2c69a0ce2c4026e7a9c1742"),
        PhononVoiceFile(name: "Josefine", file: "voices/yadpmqsHVrYC0NJp.safetensors", language: "de-DE", bytes: 256136, sha256: "f0c5e9b03ec651da1b8ae2d76f23b46381c9943e1e7c7ad434f66a6bb1a16d44"),
        PhononVoiceFile(name: "Anton", file: "voices/3ZKKapPOvuWFcw9f.safetensors", language: "de-DE", bytes: 256136, sha256: "b645c79148a02f6cd2ef7a6b3658373166e19a9a1c49fb81408be5d79667e6cb"),
        PhononVoiceFile(name: "Mirko", file: "voices/Xn9xDzqSSr4xGTNg.safetensors", language: "de-DE", bytes: 256136, sha256: "275c9024bf16518fab2c477d4acdc76cad6f2c322ce083ab56238c3856012f57"),
        PhononVoiceFile(name: "Mats", file: "voices/Kf5m22mROozoMWj3.safetensors", language: "de-DE", bytes: 256136, sha256: "1cd9e5471568fe905906742568b5d3d2e89cdac1fa8b8272780d984d7d54ec9a"),
        PhononVoiceFile(name: "Henrik", file: "voices/yyS1KYWs6mXoEw7D.safetensors", language: "de-DE", bytes: 256136, sha256: "4a1bea252ee32f44dff1852894a521bb5de0b58a3ba5f18011c84aab0ad45916"),
        PhononVoiceFile(name: "Leon", file: "voices/20zdyYrQPzKlCwkk.safetensors", language: "de-DE", bytes: 256136, sha256: "28af62a4ed8af73b560dd5f78f48045969a74306f2d85aedcb4c820025f74870"),
        PhononVoiceFile(name: "Mika", file: "voices/R3uU1GTAZJotUhUs.safetensors", language: "de-DE", bytes: 256136, sha256: "36840305b88f217cc20e153276eaaf74718e5e2b50ac05f0dd6c4606b0d576a2"),
        PhononVoiceFile(name: "Svea", file: "voices/Adoh4wA9tp5QXJi9.safetensors", language: "de-DE", bytes: 256136, sha256: "0179a71e0aa1e89320ed35da4c6dea30384f98d24ee931517916742ccf7e6002"),
        PhononVoiceFile(name: "Manuela-Lu", file: "voices/KgC2Nqnjj48NUiyV.safetensors", language: "pt-BR", bytes: 256136, sha256: "f6b455eec3ad536c2c8b7b2f18a5620cb46ebf7576a040299fce4de6376ad3a3"),
        PhononVoiceFile(name: "Isadora", file: "voices/CtNvKUUMrx1h56ih.safetensors", language: "pt-BR", bytes: 256136, sha256: "ad6f5ca7df38abbb15b85a09613b14ebd76d70108d5420e6f21486a6a10154c9"),
        PhononVoiceFile(name: "Débora", file: "voices/K8mj96kYHMy8q3Hb.safetensors", language: "pt-BR", bytes: 256136, sha256: "00d4323db427bb68d8b6eed15b1294840e2037bcabc1d6fe6385191efae414b0"),
        PhononVoiceFile(name: "Rafaela", file: "voices/6k6cRt7QJfm5ChrH.safetensors", language: "pt-BR", bytes: 256136, sha256: "96ca40ceb24b3cbbff9868c6a920f6c7ff3d471b76698d8cd8b7c542c38d814f"),
        PhononVoiceFile(name: "Clarice", file: "voices/sGCMzFIA53ppIngM.safetensors", language: "pt-BR", bytes: 256136, sha256: "edbfd1498e78dab5a1f707c4ff5a169e887741abf4e78d2e9759d242cd32b25c"),
        PhononVoiceFile(name: "Flávia", file: "voices/gOc90Rjmv5CobHCj.safetensors", language: "pt-BR", bytes: 256136, sha256: "f6e911481dd0bd60a36d77c1883f2f237b5b78275615498764a07456e8685c7c"),
        PhononVoiceFile(name: "Davi", file: "voices/NuUr_x5V90hSHzCJ.safetensors", language: "pt-BR", bytes: 256136, sha256: "593c8c56619008116b30d7ad1bae5433d6834060b5b757e51799574601badd99"),
        PhononVoiceFile(name: "Igor", file: "voices/l7520SIXi14iEamd.safetensors", language: "pt-BR", bytes: 256136, sha256: "044d37978b68c5363e0fda99873c9f657323c350d8351b4d266bf03b2f839c30"),
        PhononVoiceFile(name: "Kauã", file: "voices/6HftnVU1XqVBJS8t.safetensors", language: "pt-BR", bytes: 256136, sha256: "b0c3223c6de2597e3eef285e9def7998e9861b2056ee4784cddb29174bfc4dc4"),
        PhononVoiceFile(name: "Vitor", file: "voices/mWgyMRkFED70QxQv.safetensors", language: "pt-BR", bytes: 256136, sha256: "8732e9ed54a3380cf864152d3adfd0ed056af85f5e2f468395244a51a923842e"),
        PhononVoiceFile(name: "Otávio", file: "voices/JYtmeaysoaR0Wybf.safetensors", language: "pt-BR", bytes: 256136, sha256: "2450c247061a20c202f63caabe4594379a8fc8599f9fcbb28642a2dd3d247ad1"),
        PhononVoiceFile(name: "Marcelo", file: "voices/qDeAnE4L4bk0BRz1.safetensors", language: "pt-BR", bytes: 256136, sha256: "842930df459e1d636cdd3414cd60ab2631ebfdff29460a922415e506b1cc5ed1"),
    ]

    /// Downloads with `token`, converts into `destination` (replaced), and cleans up
    /// `workDirectory`. Progress covers the download; conversion is reported as a phase.
    static func run(_ spec: Spec, token: String, workDirectory: URL, destination: URL,
                    phase: @escaping @Sendable (Phase) -> Void) async throws {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: workDirectory)
        let checkpoint = workDirectory.appendingPathComponent("checkpoint", isDirectory: true)
        let voiceFolder = workDirectory.appendingPathComponent("voices", isDirectory: true)
        let bundle = workDirectory.appendingPathComponent("bundle", isDirectory: true)
        try fileManager.createDirectory(at: checkpoint, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: voiceFolder, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workDirectory) }

        let total = Double(spec.downloadBytes)
        var done: Int64 = 0
        phase(.downloading(0))
        for file in spec.checkpointFiles {
            let url = URL(string: "https://huggingface.co/\(spec.repository)/resolve/\(spec.revision)/\(file.path)")!
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let base = done
            try await download(request, to: checkpoint.appendingPathComponent(file.path), expected: file) { fraction in
                phase(.downloading((Double(base) + fraction * Double(file.bytes)) / total))
            }
            done += file.bytes
        }
        for voice in spec.voices {
            // Public files: no token is sent.
            let path = voice.file.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? voice.file
            let url = URL(string: "https://huggingface.co/\(voicesRepository)/resolve/\(voicesRevision)/\(path)")!
            try await download(URLRequest(url: url), to: voiceFolder.appendingPathComponent("\(voice.name).safetensors"),
                               expected: RemoteFile(path: voice.file, bytes: voice.bytes, sha256: voice.sha256)) { _ in }
            done += voice.bytes
            phase(.downloading(Double(done) / total))
        }

        try Task.checkCancellation()
        phase(.converting)
        try await Phonon.exportCoreML(checkpoint: checkpoint, voices: voiceFolder, to: bundle)
        try Task.checkCancellation()
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.moveItem(at: bundle, to: destination)
    }

    private static func download(_ request: URLRequest, to destination: URL, expected: RemoteFile,
                                 progress: @escaping @Sendable (Double) -> Void) async throws {
        var request = request
        request.timeoutInterval = 60
        let response: HTTPURLResponse = try await withCheckedThrowingContinuation { continuation in
            let task = URLSession.shared.downloadTask(with: request) { temporary, response, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let http = response as? HTTPURLResponse, let temporary else {
                    continuation.resume(throwing: PhononConversionError.invalidResponse)
                    return
                }
                if http.statusCode == 200 {
                    do {
                        try? FileManager.default.removeItem(at: destination)
                        try FileManager.default.moveItem(at: temporary, to: destination)
                    } catch {
                        continuation.resume(throwing: error)
                        return
                    }
                }
                continuation.resume(returning: http)
            }
            let observation = task.progress.observe(\.fractionCompleted) { value, _ in
                progress(value.fractionCompleted)
            }
            objc_setAssociatedObject(task, &observationKey, observation, .OBJC_ASSOCIATION_RETAIN)
            task.resume()
        }
        switch response.statusCode {
        case 200: break
        case 401: throw PhononConversionError.signInExpired
        case 403: throw PhononConversionError.accessNotGranted
        default: throw PhononConversionError.http(response.statusCode)
        }
        let size = FileStore.fileSize(at: destination)
        let hash = try ContentHash.sha256(of: destination)
        guard size == expected.bytes, hash == expected.sha256 else {
            throw PhononConversionError.integrity(expected.path)
        }
    }

    nonisolated(unsafe) private static var observationKey: UInt8 = 0
}

enum PhononConversionError: LocalizedError, Equatable {
    case notSignedIn
    case signInExpired
    case accessNotGranted
    case integrity(String)
    case http(Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            String(localized: "Sign in to Hugging Face first (Hugging Face section above), with an account that has accepted this model's conditions.")
        case .signInExpired:
            String(localized: "Hugging Face did not accept your sign-in. Sign in again and retry.")
        case .accessNotGranted:
            String(localized: "Your Hugging Face account has not accepted this model's conditions yet. Open the model page, accept them, and retry.")
        case .integrity(let file):
            String(localized: "\(file) did not match the expected file. Nothing was installed; retry the download.")
        case .http(let code):
            String(localized: "Hugging Face returned HTTP \(code). Retry later.")
        case .invalidResponse:
            String(localized: "Hugging Face returned an unexpected response.")
        }
    }
}
