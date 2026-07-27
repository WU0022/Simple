import UIKit
import AVFoundation
import AVKit
import MediaPlayer

final class CustomVideoPlayerViewController: UIViewController, AVPictureInPictureControllerDelegate {
    private let videoURL: URL
    private var player: AVPlayer?
    private var playerItem: AVPlayerItem?
    private var playerLayer: AVPlayerLayer?
    private var pipController: AVPictureInPictureController?

    private var timeObserverToken: Any?
    private var isControlsVisible = true
    private var controlsTimer: Timer?
    private var isSeeking = false
    private var isLocked = false

    private var currentSpeed: Float = 1.0
    private var currentPreloadDuration: TimeInterval = 60.0
    private var currentVideoGravity: AVLayerVideoGravity = .resizeAspect

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
    private let topGradientLayer = CAGradientLayer()
    private let bottomGradientLayer = CAGradientLayer()

    private let controlsOverlay = UIView()
    private let topBar = UIView()
    private let bottomBar = UIView()

    private let closeButton = TouchButton()
    private let titleLabel = UILabel()
    private let systemTimeLabel = UILabel()
    private let netSpeedLabel = UILabel()
    private let lockButton = TouchButton()
    private let pipButton = TouchButton()
    private let aspectButton = TouchButton()

    private let currentTimeLabel = UILabel()
    private let bufferProgressView = UIProgressView(progressViewStyle: .default)
    private let progressSlider = UISlider()
    private let totalTimeLabel = UILabel()

    private var barHeightConstraint: NSLayoutConstraint?

    private let playPauseButton = TouchButton()
    private let skipForwardButton = TouchButton()
    private let qualityButton = TouchButton()
    private let preloadButton = TouchButton()
    private let speedButton = TouchButton()

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

    override var shouldAutorotate: Bool {
        return true
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        return .allButUpsideDown
    }

    override var prefersStatusBarHidden: Bool {
        return !isControlsVisible
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupLayout()
        setupGestures()
        setupPlayer()
        updateSystemTime()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        playerLayer?.frame = playerView.bounds
        topGradientLayer.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: 120)
        bottomGradientLayer.frame = CGRect(x: 0, y: view.bounds.height - 140, width: view.bounds.width, height: 140)
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: { [weak self] _ in
            guard let self = self else { return }
            self.playerLayer?.frame = CGRect(origin: .zero, size: size)
        }, completion: nil)
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

        topGradientLayer.colors = [UIColor.black.withAlphaComponent(0.75).cgColor, UIColor.clear.cgColor]
        bottomGradientLayer.colors = [UIColor.clear.cgColor, UIColor.black.withAlphaComponent(0.85).cgColor]

        view.layer.addSublayer(topGradientLayer)
        view.layer.addSublayer(bottomGradientLayer)

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

            topBar.topAnchor.constraint(equalTo: controlsOverlay.safeAreaLayoutGuide.topAnchor, constant: 4),
            topBar.leadingAnchor.constraint(equalTo: controlsOverlay.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            topBar.trailingAnchor.constraint(equalTo: controlsOverlay.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            topBar.heightAnchor.constraint(equalToConstant: 44),

            bottomBar.bottomAnchor.constraint(equalTo: controlsOverlay.safeAreaLayoutGuide.bottomAnchor, constant: -8),
            bottomBar.leadingAnchor.constraint(equalTo: controlsOverlay.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            bottomBar.trailingAnchor.constraint(equalTo: controlsOverlay.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            bottomBar.heightAnchor.constraint(equalToConstant: 80)
        ])

        systemTimeLabel.translatesAutoresizingMaskIntoConstraints = false
        systemTimeLabel.textColor = .white
        systemTimeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .bold)

        var closeConfig = UIButton.Configuration.plain()
        closeConfig.image = UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .bold))
        closeConfig.baseForegroundColor = .white
        closeButton.configuration = closeConfig
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.addTarget(self, action: #selector(handleClose), for: .touchUpInside)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.textColor = .white
        titleLabel.font = .systemFont(ofSize: 14, weight: .bold)
        titleLabel.lineBreakMode = .byTruncatingTail

        netSpeedLabel.translatesAutoresizingMaskIntoConstraints = false
        netSpeedLabel.textColor = .white
        netSpeedLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        netSpeedLabel.text = "0.0 KB/s"

        var lockConfig = UIButton.Configuration.plain()
        lockConfig.image = UIImage(systemName: "lock.open.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .regular))
        lockConfig.baseForegroundColor = .white
        lockButton.configuration = lockConfig
        lockButton.translatesAutoresizingMaskIntoConstraints = false
        lockButton.addTarget(self, action: #selector(handleLockToggle), for: .touchUpInside)

        var pipConfig = UIButton.Configuration.plain()
        pipConfig.image = UIImage(systemName: "pip.enter", withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .regular))
        pipConfig.baseForegroundColor = .white
        pipButton.configuration = pipConfig
        pipButton.translatesAutoresizingMaskIntoConstraints = false
        pipButton.addTarget(self, action: #selector(handlePipToggle), for: .touchUpInside)

        var aspectConfig = UIButton.Configuration.plain()
        aspectConfig.image = UIImage(systemName: "aspectratio", withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .regular))
        aspectConfig.baseForegroundColor = .white
        aspectButton.configuration = aspectConfig
        aspectButton.translatesAutoresizingMaskIntoConstraints = false
        aspectButton.addTarget(self, action: #selector(handleAspectToggle), for: .touchUpInside)

        topBar.addSubview(closeButton)
        topBar.addSubview(titleLabel)
        topBar.addSubview(systemTimeLabel)
        topBar.addSubview(netSpeedLabel)
        topBar.addSubview(lockButton)
        topBar.addSubview(pipButton)
        topBar.addSubview(aspectButton)

        NSLayoutConstraint.activate([
            closeButton.leadingAnchor.constraint(equalTo: topBar.leadingAnchor),
            closeButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 32),
            closeButton.heightAnchor.constraint(equalToConstant: 32),

            titleLabel.leadingAnchor.constraint(equalTo: closeButton.trailingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: systemTimeLabel.leadingAnchor, constant: -8),
            titleLabel.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),

            aspectButton.trailingAnchor.constraint(equalTo: topBar.trailingAnchor),
            aspectButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            aspectButton.widthAnchor.constraint(equalToConstant: 32),
            aspectButton.heightAnchor.constraint(equalToConstant: 32),

            pipButton.trailingAnchor.constraint(equalTo: aspectButton.leadingAnchor, constant: -6),
            pipButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            pipButton.widthAnchor.constraint(equalToConstant: 32),
            pipButton.heightAnchor.constraint(equalToConstant: 32),

            lockButton.trailingAnchor.constraint(equalTo: pipButton.leadingAnchor, constant: -6),
            lockButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            lockButton.widthAnchor.constraint(equalToConstant: 32),
            lockButton.heightAnchor.constraint(equalToConstant: 32),

            netSpeedLabel.trailingAnchor.constraint(equalTo: lockButton.leadingAnchor, constant: -12),
            netSpeedLabel.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),

            systemTimeLabel.trailingAnchor.constraint(equalTo: netSpeedLabel.leadingAnchor, constant: -12),
            systemTimeLabel.centerYAnchor.constraint(equalTo: topBar.centerYAnchor)
        ])

        currentTimeLabel.translatesAutoresizingMaskIntoConstraints = false
        currentTimeLabel.textColor = .white
        currentTimeLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .bold)
        currentTimeLabel.text = "00:00"

        bufferProgressView.translatesAutoresizingMaskIntoConstraints = false
        bufferProgressView.progressTintColor = UIColor.white.withAlphaComponent(0.4)
        bufferProgressView.trackTintColor = UIColor.white.withAlphaComponent(0.2)
        bufferProgressView.layer.cornerRadius = 2
        bufferProgressView.clipsToBounds = true

        progressSlider.translatesAutoresizingMaskIntoConstraints = false
        progressSlider.minimumTrackTintColor = .white
        progressSlider.maximumTrackTintColor = .clear

        let transparentImage = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { _ in }
        progressSlider.setThumbImage(transparentImage, for: .normal)
        progressSlider.addTarget(self, action: #selector(handleSliderValueChanged(_:event:)), for: .valueChanged)

        totalTimeLabel.translatesAutoresizingMaskIntoConstraints = false
        totalTimeLabel.textColor = .white
        totalTimeLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .bold)
        totalTimeLabel.text = "00:00"

        var playConfig = UIButton.Configuration.plain()
        playConfig.image = UIImage(systemName: "play.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .bold))
        playConfig.baseForegroundColor = .white
        playPauseButton.configuration = playConfig
        playPauseButton.translatesAutoresizingMaskIntoConstraints = false
        playPauseButton.addTarget(self, action: #selector(handlePlayPause), for: .touchUpInside)

        var skipConfig = UIButton.Configuration.plain()
        skipConfig.image = UIImage(systemName: "forward.end.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .bold))
        skipConfig.baseForegroundColor = .white
        skipForwardButton.configuration = skipConfig
        skipForwardButton.translatesAutoresizingMaskIntoConstraints = false
        skipForwardButton.addTarget(self, action: #selector(handleSkipForward), for: .touchUpInside)

        var qualityConfig = UIButton.Configuration.plain()
        qualityConfig.title = "4K"
        qualityConfig.baseForegroundColor = .white
        qualityConfig.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = .systemFont(ofSize: 13, weight: .bold)
            return outgoing
        }
        qualityButton.configuration = qualityConfig
        qualityButton.translatesAutoresizingMaskIntoConstraints = false

        var preloadConfig = UIButton.Configuration.plain()
        preloadConfig.title = "预加载"
        preloadConfig.baseForegroundColor = .white
        preloadConfig.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = .systemFont(ofSize: 13, weight: .bold)
            return outgoing
        }
        preloadButton.configuration = preloadConfig
        preloadButton.translatesAutoresizingMaskIntoConstraints = false
        preloadButton.addTarget(self, action: #selector(handlePreloadSelect), for: .touchUpInside)

        var speedConfig = UIButton.Configuration.plain()
        speedConfig.title = "倍速"
        speedConfig.baseForegroundColor = .white
        speedConfig.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = .systemFont(ofSize: 13, weight: .bold)
            return outgoing
        }
        speedButton.configuration = speedConfig
        speedButton.translatesAutoresizingMaskIntoConstraints = false
        speedButton.addTarget(self, action: #selector(handleSpeedSelect), for: .touchUpInside)

        bottomBar.addSubview(currentTimeLabel)
        bottomBar.addSubview(bufferProgressView)
        bottomBar.addSubview(progressSlider)
        bottomBar.addSubview(totalTimeLabel)

        bottomBar.addSubview(playPauseButton)
        bottomBar.addSubview(skipForwardButton)
        bottomBar.addSubview(qualityButton)
        bottomBar.addSubview(preloadButton)
        bottomBar.addSubview(speedButton)

        barHeightConstraint = bufferProgressView.heightAnchor.constraint(equalToConstant: 4)

        NSLayoutConstraint.activate([
            currentTimeLabel.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor),
            currentTimeLabel.topAnchor.constraint(equalTo: bottomBar.topAnchor, constant: 4),

            bufferProgressView.leadingAnchor.constraint(equalTo: currentTimeLabel.trailingAnchor, constant: 12),
            bufferProgressView.trailingAnchor.constraint(equalTo: totalTimeLabel.leadingAnchor, constant: -12),
            bufferProgressView.centerYAnchor.constraint(equalTo: currentTimeLabel.centerYAnchor),
            barHeightConstraint!,

            progressSlider.leadingAnchor.constraint(equalTo: bufferProgressView.leadingAnchor),
            progressSlider.trailingAnchor.constraint(equalTo: bufferProgressView.trailingAnchor),
            progressSlider.centerYAnchor.constraint(equalTo: bufferProgressView.centerYAnchor),
            progressSlider.heightAnchor.constraint(equalToConstant: 24),

            totalTimeLabel.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor),
            totalTimeLabel.topAnchor.constraint(equalTo: bottomBar.topAnchor, constant: 4),

            playPauseButton.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor),
            playPauseButton.bottomAnchor.constraint(equalTo: bottomBar.bottomAnchor, constant: -2),
            playPauseButton.widthAnchor.constraint(equalToConstant: 32),
            playPauseButton.heightAnchor.constraint(equalToConstant: 32),

            skipForwardButton.leadingAnchor.constraint(equalTo: playPauseButton.trailingAnchor, constant: 16),
            skipForwardButton.centerYAnchor.constraint(equalTo: playPauseButton.centerYAnchor),
            skipForwardButton.widthAnchor.constraint(equalToConstant: 32),
            skipForwardButton.heightAnchor.constraint(equalToConstant: 32),

            speedButton.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor),
            speedButton.centerYAnchor.constraint(equalTo: playPauseButton.centerYAnchor),

            preloadButton.trailingAnchor.constraint(equalTo: speedButton.leadingAnchor, constant: -12),
            preloadButton.centerYAnchor.constraint(equalTo: playPauseButton.centerYAnchor),

            qualityButton.trailingAnchor.constraint(equalTo: preloadButton.leadingAnchor, constant: -12),
            qualityButton.centerYAnchor.constraint(equalTo: playPauseButton.centerYAnchor)
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
        hudLabel.font = .systemFont(ofSize: 13, weight: .semibold)
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
            hudImageView.widthAnchor.constraint(equalToConstant: 30),
            hudImageView.heightAnchor.constraint(equalToConstant: 30),

            hudLabel.topAnchor.constraint(equalTo: hudImageView.bottomAnchor, constant: 8),
            hudLabel.leadingAnchor.constraint(equalTo: hudView.leadingAnchor, constant: 4),
            hudLabel.trailingAnchor.constraint(equalTo: hudView.trailingAnchor, constant: -4)
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
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = true
        item.preferredForwardBufferDuration = currentPreloadDuration
        self.playerItem = item

        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = true
        self.player = player

        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = currentVideoGravity
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
        resetControlsTimer(delay: 3.0)
    }

    private func addTimeObserver() {
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserverToken = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self = self else { return }
            if !self.isSeeking {
                self.updateProgress(currentTime: time)
            }
            self.updateBufferAndNetworkSpeed()
        }
    }

    private func removeTimeObserver() {
        if let token = timeObserverToken {
            player?.removeTimeObserver(token)
            timeObserverToken = nil
        }
    }

    private func updateSystemTime() {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        systemTimeLabel.text = formatter.string(from: Date())
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

    private func updateBufferAndNetworkSpeed() {
        updateSystemTime()
        guard let item = playerItem else { return }

        if let timeRange = item.loadedTimeRanges.first?.timeRangeValue {
            let bufferStart = CMTimeGetSeconds(timeRange.start)
            let bufferDuration = CMTimeGetSeconds(timeRange.duration)
            let totalBuffer = bufferStart + bufferDuration
            if let duration = item.duration.isNumeric ? item.duration : nil {
                let totalSeconds = CMTimeGetSeconds(duration)
                if totalSeconds > 0 {
                    bufferProgressView.progress = Float(totalBuffer / totalSeconds)
                }
            }
        }

        if let log = item.accessLog()?.events.last {
            let bytes = log.numberOfBytesTransferred
            let duration = log.transferDuration
            if duration > 0 {
                let bytesPerSec = Double(bytes) / duration
                if bytesPerSec > 1024 * 1024 {
                    netSpeedLabel.text = String(format: "%.1f MB/s", bytesPerSec / (1024 * 1024))
                } else if bytesPerSec > 1024 {
                    netSpeedLabel.text = String(format: "%.0f KB/s", bytesPerSec / 1024)
                } else {
                    netSpeedLabel.text = "0.0 KB/s"
                }
            }
        }
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

    private func setProgressBarExpanded(_ expanded: Bool) {
        barHeightConstraint?.constant = expanded ? 7 : 4
        bufferProgressView.layer.cornerRadius = expanded ? 3.5 : 2
        UIView.animate(withDuration: 0.15) {
            self.view.layoutIfNeeded()
        }
    }

    @objc private func handleClose() {
        dismiss(animated: true)
    }

    @objc private func handlePlayPause() {
        guard let player = player else { return }
        if player.timeControlStatus == .playing {
            player.pause()
            playPauseButton.setImage(UIImage(systemName: "play.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .bold)), for: .normal)
        } else {
            player.play()
            player.rate = currentSpeed
            playPauseButton.setImage(UIImage(systemName: "pause.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .bold)), for: .normal)
        }
        resetControlsTimer(delay: 1.0)
    }

    @objc private func handleSkipForward() {
        guard let player = player else { return }
        let current = player.currentTime()
        let targetTime = CMTimeAdd(current, CMTime(seconds: 10, preferredTimescale: 600))
        player.seek(to: targetTime)
        resetControlsTimer(delay: 1.0)
    }

    @objc private func handleLockToggle() {
        isLocked.toggle()
        let lockImage = isLocked ? "lock.fill" : "lock.open.fill"
        lockButton.setImage(UIImage(systemName: lockImage, withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .regular)), for: .normal)

        closeButton.isHidden = isLocked
        titleLabel.isHidden = isLocked
        systemTimeLabel.isHidden = isLocked
        netSpeedLabel.isHidden = isLocked
        pipButton.isHidden = isLocked || !AVPictureInPictureController.isPictureInPictureSupported()
        aspectButton.isHidden = isLocked
        bottomBar.isHidden = isLocked

        showHUD(imageName: isLocked ? "lock.fill" : "lock.open.fill", text: isLocked ? "屏幕已锁定" : "屏幕已解锁")
        hideHUD()
        resetControlsTimer(delay: 1.0)
    }

    @objc private func handlePipToggle() {
        guard let pip = pipController else { return }
        if pip.isPictureInPictureActive {
            pip.stopPictureInPicture()
        } else {
            pip.startPictureInPicture()
        }
    }

    @objc private func handleAspectToggle() {
        if currentVideoGravity == .resizeAspect {
            currentVideoGravity = .resizeAspectFill
            showHUD(imageName: "arrow.up.left.and.arrow.down.right", text: "填满屏幕")
        } else {
            currentVideoGravity = .resizeAspect
            showHUD(imageName: "arrow.down.right.and.arrow.up.left", text: "适应窗口")
        }
        playerLayer?.videoGravity = currentVideoGravity
        hideHUD()
        resetControlsTimer(delay: 1.0)
    }

    @objc private func handleSpeedSelect() {
        let alert = UIAlertController(title: "播放倍速", message: nil, preferredStyle: .actionSheet)
        let speeds: [(String, Float)] = [
            ("0.5x", 0.5),
            ("0.75x", 0.75),
            ("1.0x (正常)", 1.0),
            ("1.25x", 1.25),
            ("1.5x", 1.5),
            ("2.0x", 2.0)
        ]
        for (title, val) in speeds {
            alert.addAction(UIAlertAction(title: title, style: .default) { [weak self] _ in
                guard let self = self else { return }
                self.currentSpeed = val
                self.player?.rate = val
                var speedConfig = UIButton.Configuration.plain()
                speedConfig.title = val == 1.0 ? "倍速" : "\(val)x"
                speedConfig.baseForegroundColor = .white
                speedConfig.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
                    var outgoing = incoming
                    outgoing.font = .systemFont(ofSize: 13, weight: .bold)
                    return outgoing
                }
                self.speedButton.configuration = speedConfig
                self.resetControlsTimer(delay: 1.0)
            })
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(alert, animated: true)
    }

    @objc private func handlePreloadSelect() {
        let alert = UIAlertController(title: "预加载缓冲区", message: "调大预加载范围可在弱网下获得更顺畅的播放体验", preferredStyle: .actionSheet)
        let options: [(String, TimeInterval)] = [
            ("自动 (系统默认)", 0),
            ("预加载 30 秒", 30.0),
            ("预加载 60 秒", 60.0),
            ("预加载 180 秒 (3分钟)", 180.0),
            ("预加载 360 秒 (6分钟)", 360.0),
            ("自定义预加载秒数...", -1.0)
        ]
        for (title, dur) in options {
            alert.addAction(UIAlertAction(title: title, style: .default) { [weak self] _ in
                guard let self = self else { return }
                if dur < 0 {
                    self.showCustomPreloadInputDialog()
                } else {
                    self.applyPreloadDuration(dur)
                }
            })
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(alert, animated: true)
    }

    private func showCustomPreloadInputDialog() {
        let alert = UIAlertController(title: "自定义预加载", message: "请输入预加载秒数 (如 500)", preferredStyle: .alert)
        alert.addTextField { tf in
            tf.placeholder = "预加载秒数"
            tf.keyboardType = .numberPad
        }
        alert.addAction(UIAlertAction(title: "确定", style: .default) { [weak self] _ in
            guard let text = alert.textFields?[0].text?.trimmingCharacters(in: .whitespaces),
                  let val = Double(text), val > 0 else { return }
            self?.applyPreloadDuration(val)
        })
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(alert, animated: true)
    }

    private func applyPreloadDuration(_ duration: TimeInterval) {
        currentPreloadDuration = duration
        playerItem?.preferredForwardBufferDuration = duration
        var preloadConfig = UIButton.Configuration.plain()
        preloadConfig.title = duration == 0 ? "预加载" : "\(Int(duration))s"
        preloadConfig.baseForegroundColor = .white
        preloadConfig.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = .systemFont(ofSize: 13, weight: .bold)
            return outgoing
        }
        preloadButton.configuration = preloadConfig
        resetControlsTimer(delay: 1.0)
    }

    @objc private func handleSingleTap() {
        isControlsVisible.toggle()
        UIView.animate(withDuration: 0.25) {
            self.controlsOverlay.alpha = self.isControlsVisible ? 1.0 : 0.0
            self.topGradientLayer.opacity = self.isControlsVisible ? 1.0 : 0.0
            self.bottomGradientLayer.opacity = self.isControlsVisible ? 1.0 : 0.0
        }
        setNeedsStatusBarAppearanceUpdate()
        if isControlsVisible {
            resetControlsTimer(delay: 3.0)
        }
    }

    @objc private func handleDoubleTap() {
        if !isLocked {
            handlePlayPause()
        }
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
                setProgressBarExpanded(true)
            case .moved:
                currentTimeLabel.text = formatTime(seconds: targetSeconds)
            case .ended, .cancelled:
                setProgressBarExpanded(false)
                player?.seek(to: targetTime, completionHandler: { [weak self] _ in
                    self?.isSeeking = false
                    self?.resetControlsTimer(delay: 1.0)
                })
            default:
                break
            }
        }
    }

    @objc private func handlePanGesture(_ gesture: UIPanGestureRecognizer) {
        guard !isLocked else { return }
        let location = gesture.location(in: view)
        let translation = gesture.translation(in: view)
        let velocity = gesture.velocity(in: view)

        switch gesture.state {
        case .began:
            if abs(velocity.x) > abs(velocity.y) {
                panDirection = .horizontal
                panStartSeekTime = player?.currentTime() ?? .zero
                isSeeking = true
                setProgressBarExpanded(true)
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

                progressSlider.value = Float(targetSeconds / totalSeconds)
                currentTimeLabel.text = formatTime(seconds: targetSeconds)
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
                setProgressBarExpanded(false)
                guard let duration = player?.currentItem?.duration, duration.isNumeric else { return }
                let totalSeconds = CMTimeGetSeconds(duration)
                let deltaSeconds = Double(translation.x / view.bounds.width) * 90.0
                let currentSeconds = CMTimeGetSeconds(panStartSeekTime)
                let targetSeconds = min(max(0, currentSeconds + deltaSeconds), totalSeconds)
                let targetTime = CMTime(seconds: targetSeconds, preferredTimescale: 600)

                player?.seek(to: targetTime, completionHandler: { [weak self] _ in
                    self?.isSeeking = false
                    self?.resetControlsTimer(delay: 1.0)
                })
            } else {
                hideHUD()
            }
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

    private func resetControlsTimer(delay: TimeInterval = 1.0) {
        controlsTimer?.invalidate()
        controlsTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            guard let self = self, self.isControlsVisible && !self.isSeeking else { return }
            self.isControlsVisible = false
            UIView.animate(withDuration: 0.25) {
                self.controlsOverlay.alpha = 0.0
                self.topGradientLayer.opacity = 0.0
                self.bottomGradientLayer.opacity = 0.0
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
