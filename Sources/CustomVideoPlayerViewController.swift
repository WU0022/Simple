import UIKit
import AVFoundation
import AVKit
import MediaPlayer

final class CustomVideoPlayerViewController: UIViewController, AVPictureInPictureControllerDelegate {
    private let videoURL: URL
    private var player: AVPlayer?
    private var playerLayer: AVPlayerLayer?
    private var pipController: AVPictureInPictureController?

    private var timeObserverToken: Any?
    private var isControlsVisible = true
    private var controlsTimer: Timer?
    private var isSeeking = false

    private enum PanGestureDirection {
        case unknown
        case horizontal
        case verticalLeft
        case verticalRight
    }

    private var panDirection: PanGestureDirection = .unknown
    private var panStartSeekTime: CMTime = .zero
    private var panStartBrightness: CGFloat = 0.5
    private var panStartVolume: Float = 0.5
    private let volumeView = MPVolumeView()

    private let playerView = UIView()
    private let controlsOverlay = UIView()
    private let topBar = UIView()
    private let bottomBar = UIView()

    private let closeButton = TouchButton()
    private let pipButton = TouchButton()
    private let titleLabel = UILabel()

    private let playPauseButton = TouchButton()
    private let progressSlider = UISlider()
    private let currentTimeLabel = UILabel()
    private let totalTimeLabel = UILabel()

    private let hudView = UIView()
    private let hudImageView = UIImageView()
    private let hudLabel = UILabel()

    private let activityIndicator = UIActivityIndicatorView(style: .large)

    init(videoURL: URL, title: String? = nil) {
        self.videoURL = videoURL
        super.init(nibName: nil, bundle: nil)
        if let t = title, !t.isEmpty {
            self.titleLabel.text = t
        } else {
            self.titleLabel.text = videoURL.lastPathComponent
        }
        modalPresentationStyle = .fullScreen
    }

    required init?(coder: NSCoder) { nil }

    override var prefersStatusBarHidden: Bool {
        return !isControlsVisible
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        return .allButUpsideDown
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupLayout()
        setupGestures()
        setupPlayer()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        playerLayer?.frame = playerView.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        player?.pause()
        removeTimeObserver()
    }

    deinit {
        removeTimeObserver()
        controlsTimer?.invalidate()
    }

    private func setupLayout() {
        playerView.translatesAutoresizingMaskIntoConstraints = false
        controlsOverlay.translatesAutoresizingMaskIntoConstraints = false
        topBar.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(playerView)
        view.addSubview(controlsOverlay)

        controlsOverlay.addSubview(topBar)
        controlsOverlay.addSubview(bottomBar)

        NSLayoutConstraint.activate([
            playerView.topAnchor.constraint(equalTo: view.topAnchor),
            playerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            playerView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            controlsOverlay.topAnchor.constraint(equalTo: view.topAnchor),
            controlsOverlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controlsOverlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            controlsOverlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            topBar.topAnchor.constraint(equalTo: controlsOverlay.safeAreaLayoutGuide.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: controlsOverlay.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: controlsOverlay.trailingAnchor),
            topBar.heightAnchor.constraint(equalToConstant: 50),

            bottomBar.bottomAnchor.constraint(equalTo: controlsOverlay.safeAreaLayoutGuide.bottomAnchor),
            bottomBar.leadingAnchor.constraint(equalTo: controlsOverlay.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: controlsOverlay.trailingAnchor),
            bottomBar.heightAnchor.constraint(equalToConstant: 60)
        ])

        var closeConfig = UIButton.Configuration.plain()
        closeConfig.image = UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .bold))
        closeConfig.baseForegroundColor = .white
        closeButton.configuration = closeConfig
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.addTarget(self, action: #selector(handleClose), for: .touchUpInside)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.textColor = .white
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)

        var pipConfig = UIButton.Configuration.plain()
        pipConfig.image = UIImage(systemName: "pip.enter", withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .regular))
        pipConfig.baseForegroundColor = .white
        pipButton.configuration = pipConfig
        pipButton.translatesAutoresizingMaskIntoConstraints = false
        pipButton.addTarget(self, action: #selector(handlePipToggle), for: .touchUpInside)

        topBar.addSubview(closeButton)
        topBar.addSubview(titleLabel)
        topBar.addSubview(pipButton)

        NSLayoutConstraint.activate([
            closeButton.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 12),
            closeButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 40),
            closeButton.heightAnchor.constraint(equalToConstant: 40),

            titleLabel.leadingAnchor.constraint(equalTo: closeButton.trailingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(equalTo: pipButton.leadingAnchor, constant: -8),
            titleLabel.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),

            pipButton.trailingAnchor.constraint(equalTo: topBar.trailingAnchor, constant: -12),
            pipButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            pipButton.widthAnchor.constraint(equalToConstant: 40),
            pipButton.heightAnchor.constraint(equalToConstant: 40)
        ])

        var playConfig = UIButton.Configuration.plain()
        playConfig.image = UIImage(systemName: "pause.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .medium))
        playConfig.baseForegroundColor = .white
        playPauseButton.configuration = playConfig
        playPauseButton.translatesAutoresizingMaskIntoConstraints = false
        playPauseButton.addTarget(self, action: #selector(handlePlayPause), for: .touchUpInside)

        currentTimeLabel.translatesAutoresizingMaskIntoConstraints = false
        currentTimeLabel.textColor = .white
        currentTimeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        currentTimeLabel.text = "00:00"

        progressSlider.translatesAutoresizingMaskIntoConstraints = false
        progressSlider.minimumTrackTintColor = .systemBlue
        progressSlider.maximumTrackTintColor = UIColor.white.withAlphaComponent(0.3)
        progressSlider.thumbTintColor = .white
        progressSlider.addTarget(self, action: #selector(handleSliderValueChanged(_:event:)), for: .valueChanged)

        totalTimeLabel.translatesAutoresizingMaskIntoConstraints = false
        totalTimeLabel.textColor = .white
        totalTimeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        totalTimeLabel.text = "00:00"

        bottomBar.addSubview(playPauseButton)
        bottomBar.addSubview(currentTimeLabel)
        bottomBar.addSubview(progressSlider)
        bottomBar.addSubview(totalTimeLabel)

        NSLayoutConstraint.activate([
            playPauseButton.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor, constant: 12),
            playPauseButton.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),
            playPauseButton.widthAnchor.constraint(equalToConstant: 40),
            playPauseButton.heightAnchor.constraint(equalToConstant: 40),

            currentTimeLabel.leadingAnchor.constraint(equalTo: playPauseButton.trailingAnchor, constant: 8),
            currentTimeLabel.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),

            progressSlider.leadingAnchor.constraint(equalTo: currentTimeLabel.trailingAnchor, constant: 12),
            progressSlider.trailingAnchor.constraint(equalTo: totalTimeLabel.leadingAnchor, constant: -12),
            progressSlider.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),

            totalTimeLabel.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor, constant: -16),
            totalTimeLabel.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor)
        ])

        hudView.translatesAutoresizingMaskIntoConstraints = false
        hudView.backgroundColor = UIColor.black.withAlphaComponent(0.75)
        hudView.layer.cornerRadius = 12
        hudView.clipsToBounds = true
        hudView.alpha = 0

        hudImageView.translatesAutoresizingMaskIntoConstraints = false
        hudImageView.tintColor = .white
        hudImageView.contentMode = .scaleAspectFit

        hudLabel.translatesAutoresizingMaskIntoConstraints = false
        hudLabel.textColor = .white
        hudLabel.font = .systemFont(ofSize: 14, weight: .medium)
        hudLabel.textAlignment = .center

        hudView.addSubview(hudImageView)
        hudView.addSubview(hudLabel)

        view.addSubview(hudView)

        NSLayoutConstraint.activate([
            hudView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            hudView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            hudView.widthAnchor.constraint(equalToConstant: 120),
            hudView.heightAnchor.constraint(equalToConstant: 90),

            hudImageView.centerXAnchor.constraint(equalTo: hudView.centerXAnchor),
            hudImageView.topAnchor.constraint(equalTo: hudView.topAnchor, constant: 16),
            hudImageView.widthAnchor.constraint(equalToConstant: 32),
            hudImageView.heightAnchor.constraint(equalToConstant: 32),

            hudLabel.topAnchor.constraint(equalTo: hudImageView.bottomAnchor, constant: 8),
            hudLabel.leadingAnchor.constraint(equalTo: hudView.leadingAnchor, constant: 6),
            hudLabel.trailingAnchor.constraint(equalTo: hudView.trailingAnchor, constant: -6)
        ])

        activityIndicator.translatesAutoresizingMaskIntoConstraints = false
        activityIndicator.color = .white
        activityIndicator.hidesWhenStopped = true
        view.addSubview(activityIndicator)

        NSLayoutConstraint.activate([
            activityIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            activityIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])

        volumeView.frame = CGRect(x: -1000, y: -1000, width: 1, height: 1)
        view.addSubview(volumeView)
    }

    private func setupGestures() {
        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap))
        singleTap.numberOfTapsRequired = 1

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap))
        doubleTap.numberOfTapsRequired = 2

        singleTap.require(toFail: doubleTap)

        view.addGestureRecognizer(singleTap)
        view.addGestureRecognizer(doubleTap)

        let panGesture = UIPanGestureRecognizer(target: self, action: #selector(handlePanGesture(_:)))
        view.addGestureRecognizer(panGesture)
    }

    private func setupPlayer() {
        activityIndicator.startAnimating()

        let item = AVPlayerItem(url: videoURL)
        let player = AVPlayer(playerItem: item)
        self.player = player

        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspect
        playerView.layer.addSublayer(layer)
        self.playerLayer = layer

        if AVPictureInPictureController.isPictureInPictureSupported() {
            pipController = AVPictureInPictureController(playerLayer: layer)
            pipController?.delegate = self
            pipButton.isHidden = false
        } else {
            pipButton.isHidden = true
        }

        addTimeObserver()

        player.play()
        resetControlsTimer()
    }

    private func addTimeObserver() {
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserverToken = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self = self, !self.isSeeking else { return }
            self.updateProgress(currentTime: time)
        }
    }

    private func removeTimeObserver() {
        if let token = timeObserverToken {
            player?.removeTimeObserver(token)
            timeObserverToken = nil
        }
    }

    private func updateProgress(currentTime: CMTime) {
        guard let duration = player?.currentItem?.duration, duration.isNumeric else { return }
        let currentSeconds = CMTimeGetSeconds(currentTime)
        let totalSeconds = CMTimeGetSeconds(duration)

        if activityIndicator.isAnimating {
            activityIndicator.stopAnimating()
        }

        progressSlider.value = Float(currentSeconds / totalSeconds)
        currentTimeLabel.text = formatTime(seconds: currentSeconds)
        totalTimeLabel.text = formatTime(seconds: totalSeconds)
    }

    private func formatTime(seconds: Double) -> String {
        guard !seconds.isNaN && !seconds.isInfinite else { return "00:00" }
        let sec = Int(seconds) % 60
        let min = (Int(seconds) / 60) % 60
        let hrs = Int(seconds) / 3600

        if hrs > 0 {
            return String(format: "%02d:%02d:%02d", hrs, min, sec)
        } else {
            return String(format: "%02d:%02d", min, sec)
        }
    }

    @objc private func handleClose() {
        dismiss(animated: true)
    }

    @objc private func handlePlayPause() {
        guard let player = player else { return }
        if player.timeControlStatus == .playing {
            player.pause()
            playPauseButton.setImage(UIImage(systemName: "play.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .medium)), for: .normal)
        } else {
            player.play()
            playPauseButton.setImage(UIImage(systemName: "pause.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .medium)), for: .normal)
        }
        resetControlsTimer()
    }

    @objc private func handlePipToggle() {
        guard let pip = pipController else { return }
        if pip.isPictureInPictureActive {
            pip.stopPictureInPicture()
        } else {
            pip.startPictureInPicture()
        }
    }

    @objc private func handleSingleTap() {
        isControlsVisible.toggle()
        UIView.animate(withDuration: 0.25) {
            self.controlsOverlay.alpha = self.isControlsVisible ? 1.0 : 0.0
        }
        setNeedsStatusBarAppearanceUpdate()
        if isControlsVisible {
            resetControlsTimer()
        }
    }

    @objc private func handleDoubleTap() {
        handlePlayPause()
    }

    @objc private func handleSliderValueChanged(_ slider: UISlider, event: UIEvent) {
        guard let duration = player?.currentItem?.duration, duration.isNumeric else { return }
        let totalSeconds = CMTimeGetSeconds(duration)
        let targetSeconds = totalSeconds * Double(slider.value)
        let targetTime = CMTime(seconds: targetSeconds, preferredTimescale: 600)

        if let touch = event.allTouches?.first {
            switch touch.phase {
            case .began:
                isSeeking = true
                controlsTimer?.invalidate()
            case .moved:
                currentTimeLabel.text = formatTime(seconds: targetSeconds)
            case .ended, .cancelled:
                player?.seek(to: targetTime, completionHandler: { [weak self] _ in
                    self?.isSeeking = false
                    self?.resetControlsTimer()
                })
            default:
                break
            }
        }
    }

    @objc private func handlePanGesture(_ gesture: UIPanGestureRecognizer) {
        let location = gesture.location(in: view)
        let translation = gesture.translation(in: view)
        let velocity = gesture.velocity(in: view)

        switch gesture.state {
        case .began:
            if abs(velocity.x) > abs(velocity.y) {
                panDirection = .horizontal
                panStartSeekTime = player?.currentTime() ?? .zero
                isSeeking = true
            } else {
                if location.x < view.bounds.width / 2 {
                    panDirection = .verticalLeft
                    panStartBrightness = UIScreen.main.brightness
                } else {
                    panDirection = .verticalRight
                    panStartVolume = getSystemVolume()
                }
            }
        case .changed:
            switch panDirection {
            case .horizontal:
                guard let duration = player?.currentItem?.duration, duration.isNumeric else { return }
                let totalSeconds = CMTimeGetSeconds(duration)
                let deltaSeconds = Double(translation.x / view.bounds.width) * 90.0
                let currentSeconds = CMTimeGetSeconds(panStartSeekTime)
                let targetSeconds = min(max(0, currentSeconds + deltaSeconds), totalSeconds)

                showHUD(
                    imageName: deltaSeconds >= 0 ? "forward.fill" : "backward.fill",
                    text: "\(formatTime(seconds: targetSeconds)) / \(formatTime(seconds: totalSeconds))"
                )
            case .verticalLeft:
                let delta = -translation.y / view.bounds.height
                let newBrightness = min(max(0, panStartBrightness + delta), 1.0)
                UIScreen.main.brightness = newBrightness
                showHUD(imageName: "sun.max.fill", text: "\(Int(newBrightness * 100))%")
            case .verticalRight:
                let delta = -translation.y / view.bounds.height
                let newVolume = min(max(0, panStartVolume + Float(delta)), 1.0)
                setSystemVolume(newVolume)
                showHUD(imageName: newVolume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill", text: "\(Int(newVolume * 100))%")
            case .unknown:
                break
            }
        case .ended, .cancelled:
            if panDirection == .horizontal {
                guard let duration = player?.currentItem?.duration, duration.isNumeric else { return }
                let totalSeconds = CMTimeGetSeconds(duration)
                let deltaSeconds = Double(translation.x / view.bounds.width) * 90.0
                let currentSeconds = CMTimeGetSeconds(panStartSeekTime)
                let targetSeconds = min(max(0, currentSeconds + deltaSeconds), totalSeconds)
                let targetTime = CMTime(seconds: targetSeconds, preferredTimescale: 600)

                player?.seek(to: targetTime, completionHandler: { [weak self] _ in
                    self?.isSeeking = false
                    self?.resetControlsTimer()
                })
            }
            hideHUD()
            panDirection = .unknown
        default:
            break
        }
    }

    private func showHUD(imageName: String, text: String) {
        hudImageView.image = UIImage(systemName: imageName)
        hudLabel.text = text
        UIView.animate(withDuration: 0.15) {
            self.hudView.alpha = 1.0
        }
    }

    private func hideHUD() {
        UIView.animate(withDuration: 0.25, delay: 0.3, options: [], animations: {
            self.hudView.alpha = 0.0
        }, completion: nil)
    }

    private func resetControlsTimer() {
        controlsTimer?.invalidate()
        controlsTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: false) { [weak self] _ in
            guard let self = self, self.isControlsVisible && !self.isSeeking else { return }
            self.isControlsVisible = false
            UIView.animate(withDuration: 0.25) {
                self.controlsOverlay.alpha = 0.0
            }
            self.setNeedsStatusBarAppearanceUpdate()
        }
    }

    private func getSystemVolume() -> Float {
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(true)
        return session.outputVolume
    }

    private func setSystemVolume(_ value: Float) {
        let slider = volumeView.subviews.first(where: { $0 is UISlider }) as? UISlider
        DispatchQueue.main.async {
            slider?.value = value
        }
    }
}
