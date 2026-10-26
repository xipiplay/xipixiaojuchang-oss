import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

/// 生图编辑提示词弹窗右栏、当前图下面的「音色」（2026-10-26 用户：音色和参考图一样绑在这个形象上，给生视频「全能参考」用）。只有角色卡有。
///
/// 标题行「音色 [文本 | 音频]」二选一，下面只显示选中的那一种（两边填的都留着；2026-10-26 用户：收进一行、说明文字不占地方）。
/// 每张卡只管自己的，不沿用别的卡（见 `CardVoice`）。
/// 和左栏的「素材」分开放：素材是传给生图模型的参考图（按顺序编「图N」），音色**不传给生图模型**、不占编号，
/// 而且跟着卡走——换版本、重新生图都不动它。所以**改了马上存**，不跟着弹窗「关掉就回滚」（不然绑个音色还得重新出一张图）。
struct CardVoiceRow: View {
    @Environment(AppModel.self) private var app
    let card: ImageGenItem

    @State private var text = ""
    @FocusState private var textFocused: Bool
    @State private var showImporter = false
    @State private var hint: String?
    @State private var player = VoicePreviewPlayer()

    var body: some View {
        let audio = CardVoice.audio(of: card, library: { app.libraryItem($0) })
        let mode = CardVoice.mode(of: card)
        VStack(alignment: .leading, spacing: 8) {
            // 标题行（2026-10-26 用户：二选一并进一行，说明文字不占地方）：音色 [文本 | 音频]　　更换
            HStack(spacing: 10) {
                Text("音色").font(.system(size: 13, weight: .semibold))
                    .help("只给生视频用，不传给生图模型；改了马上保存，换版本、重新生图都不会动它")
                Picker("", selection: Binding(get: { mode }, set: { app.updateImageItemVoiceMode(card.id, mode: $0) })) {
                    Text("文本").tag(VoiceMode.text)
                    Text("音频").tag(VoiceMode.audio)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 110)
                .help("生视频时用哪一种（两边填的都留着）")
                Spacer(minLength: 4)
                if mode == .audio, audio != nil { replaceMenu }
            }
            if mode == .text {
                TextField("请输入音色描述，如：低沉沙哑的中年男声，语速慢", text: $text, axis: .vertical)
                    .lineLimit(2...4)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($textFocused)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(textFocused ? Theme.accent.opacity(0.6) : Theme.hairline))
            } else if let audio {
                playerBox(audio)
            } else {
                HStack(spacing: 6) {
                    uploadButton
                    bindMenu
                }
                .padding(10)
                .frame(maxWidth: .infinity, minHeight: 56)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
            }
            if let hint {
                Text(hint).font(.caption2).foregroundStyle(Theme.warning)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(.insetFill))
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.audio]) { result in
            guard case .success(let url) = result else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            guard let id = app.addLibraryFiles([url]).first else {
                hint = "只支持 mp3 / wav / aac / m4a"
                return
            }
            hint = nil
            player.stop()
            app.updateImageItemVoiceAudio(card.id, audioID: id)
        }
        .onAppear { text = card.voiceText ?? "" }
        .onChange(of: card.id) { _, _ in player.stop(); text = card.voiceText ?? "" }
        .onChange(of: card.voiceAudioID) { _, _ in player.stop() }
        .onChange(of: card.voiceText) { _, new in if !textFocused { text = new ?? "" } }
        .onChange(of: textFocused) { _, focused in if !focused { saveText() } }
        .onDisappear { saveText(); player.stop() }
    }

    /// 播放器：圆形播放键 + 名字 + 能拖的进度条 +「已播 / 总长」，右上角 × 解绑
    private func playerBox(_ item: LibraryItem) -> some View {
        let loaded = player.itemID == item.id
        let total = (loaded ? player.duration : nil) ?? item.duration ?? 0
        let current = loaded ? player.time : 0
        return HStack(spacing: 12) {
            Button { toggle(item) } label: {
                Image(systemName: loaded && player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Color.primary.opacity(0.08)))
            }
            .buttonStyle(QuietButtonStyle(hover: .none))
            .help(loaded && player.isPlaying ? "暂停" : "试听")
            VStack(alignment: .leading, spacing: 4) {
                Text(item.matchName).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                Slider(value: Binding(get: { min(current, max(total, 0.01)) },
                                      set: { value in
                                          if !loaded { load(item) }
                                          player.seek(to: value)
                                      }),
                       in: 0...max(total, 0.01))
                    .controlSize(.small)
                    .disabled(total <= 0)
                Text("\(Self.clock(current)) / \(Self.clock(total))")
                    .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .padding(.leading, 12).padding(.trailing, 30).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
        .overlay(alignment: .topTrailing) {
            Button {
                player.stop()
                app.updateImageItemVoiceAudio(card.id, audioID: nil)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Color.primary.opacity(0.08)))
            }
            .buttonStyle(QuietButtonStyle(hover: .none))
            .help("解绑这段音频（素材库里的不删）")
            .padding(6)
        }
    }

    private var uploadButton: some View {
        Button { showImporter = true } label: {
            Label("上传音频", systemImage: "square.and.arrow.up").font(.caption)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(OutlineButtonStyle())
        .controlSize(.small)
        .help("选一段音频，进本项目素材库并绑到这张卡")
    }

    /// 「绑定已有」：本项目素材库里的音频（还没绑音频时，和「上传音频」并排）
    private var bindMenu: some View {
        Menu {
            audioChoices
        } label: {
            Label("绑定已有", systemImage: "link").font(.caption)
                .frame(maxWidth: .infinity)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(OutlineButtonStyle())
        .controlSize(.small)
        .help("从本项目素材库里选一段音频")
    }

    /// 已经绑了音频：标题行右边「更换」（上传一段新的 / 绑库里已有的）
    private var replaceMenu: some View {
        Menu {
            Button("上传音频…") { showImporter = true }
            Divider()
            audioChoices
        } label: {
            Text("更换").font(.caption)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(QuietButtonStyle(hover: .capsule))
        .foregroundStyle(.secondary)
        .fixedSize()
        .help("换一段音频")
    }

    @ViewBuilder
    private var audioChoices: some View {
        let audios = app.currentProjectLibrary.filter { $0.kind == .audio }
        if audios.isEmpty {
            Text("素材库里还没有音频")
        }
        ForEach(audios) { item in
            Button {
                hint = nil
                player.stop()
                app.updateImageItemVoiceAudio(card.id, audioID: item.id)
            } label: {
                Text(item.duration.map { "\(item.matchName)（\(Self.clock($0))）" } ?? item.matchName)
            }
        }
    }

    private func saveText() {
        app.updateImageItemVoiceText(card.id, text: text)
    }

    private func load(_ item: LibraryItem) {
        guard let url = item.existingLocalImageURL ?? item.remoteURL.flatMap(URL.init(string:)) else {
            hint = "这段音频的文件找不到了"
            return
        }
        player.load(url, id: item.id, duration: item.duration)
    }

    private func toggle(_ item: LibraryItem) {
        if player.itemID != item.id { load(item) }
        player.togglePlay()
    }

    static func clock(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// 音色试听：一个 AVPlayer + 播放进度（给进度条和「已播 / 总长」用）
@MainActor @Observable
final class VoicePreviewPlayer {
    private(set) var itemID: UUID?
    private(set) var time: Double = 0
    private(set) var duration: Double?
    private(set) var isPlaying = false
    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?

    func load(_ url: URL, id: UUID, duration known: Double?) {
        stop()
        let item = AVPlayerItem(url: url)
        let next = AVPlayer(playerItem: item)
        player = next
        itemID = id
        duration = known
        timeObserver = next.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.time = t.seconds.isFinite ? t.seconds : 0
                if let d = next.currentItem?.duration.seconds, d.isFinite, d > 0 { self.duration = d }
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isPlaying = false
                self.player?.seek(to: .zero)
                self.time = 0
            }
        }
    }

    func togglePlay() {
        guard let player else { return }
        if isPlaying { player.pause() } else { player.play() }
        isPlaying.toggle()
    }

    func seek(to seconds: Double) {
        time = seconds
        player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func stop() {
        player?.pause()
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        timeObserver = nil
        endObserver = nil
        player = nil
        itemID = nil
        time = 0
        duration = nil
        isPlaying = false
    }
}
