import SwiftUI
import WebKit

struct YouTubePlayerView: UIViewRepresentable {
    let model: YouTubePlayerModel

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeUIView(context: Context) -> WKWebView {
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: "listenLater")

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.isScrollEnabled = false
        webView.accessibilityLabel = "YouTube video player"
        model.attach(webView: webView)
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.kevinthau.ListenLater"
        let clientOrigin = "https://\(bundleIdentifier)"
        let html = Self.playerHTML.replacingOccurrences(
            of: "__CLIENT_ORIGIN__",
            with: clientOrigin
        )
        webView.loadHTMLString(html, baseURL: URL(string: clientOrigin))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        model.attach(webView: webView)
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: "listenLater"
        )
        webView.stopLoading()
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        private let model: YouTubePlayerModel

        init(model: YouTubePlayerModel) {
            self.model = model
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard
                let payload = message.body as? [String: Any],
                let type = payload["type"] as? String
            else { return }

            let loadID = (payload["loadId"] as? String).flatMap(UUID.init(uuidString:))
            let videoID = payload["videoId"] as? String

            Task { @MainActor in
                switch type {
                case "ready":
                    model.receive(.ready, loadID: nil, videoID: nil)
                case "playing":
                    model.receive(.playing, loadID: loadID, videoID: videoID)
                case "buffering":
                    model.receive(.buffering, loadID: loadID, videoID: videoID)
                case "paused":
                    model.receive(.paused, loadID: loadID, videoID: videoID)
                case "ended":
                    model.receive(.ended, loadID: loadID, videoID: videoID)
                case "progress":
                    let position = payload["position"] as? Double ?? 0
                    let duration = payload["duration"] as? Double ?? 0
                    model.receive(
                        .progress(position: position, duration: duration),
                        loadID: loadID,
                        videoID: videoID
                    )
                case "rateChanged":
                    model.receive(
                        .playbackRateChanged(payload["rate"] as? Double ?? 1),
                        loadID: loadID,
                        videoID: videoID
                    )
                case "autoplayBlocked":
                    model.receive(
                        .autoplayBlocked,
                        loadID: loadID,
                        videoID: videoID
                    )
                case "error":
                    model.receive(
                        .failed(code: payload["code"] as? Int ?? -1),
                        loadID: loadID,
                        videoID: videoID
                    )
                default:
                    break
                }
            }
        }
    }

    private static let playerHTML = """
    <!doctype html>
    <html>
    <head>
      <meta name="viewport" content="initial-scale=1, width=device-width, viewport-fit=cover">
      <style>
        html, body, #player-container, .player-mount, #player-container iframe {
          width: 100%; height: 100%; margin: 0; background: #000; overflow: hidden;
        }
      </style>
    </head>
    <body>
      <div id="player-container"></div>
      <script src="https://www.youtube.com/iframe_api"></script>
      <script>
        let player = null;
        let pending = null;
        let activeRequest = null;
        let progressTimer = null;
        let apiReady = false;
        let playerGeneration = 0;

        function post(type, values = {}) {
          window.webkit.messageHandlers.listenLater.postMessage({ type, ...values });
        }

        function isCurrentRequest(generation, request) {
          return generation === playerGeneration && request === activeRequest;
        }

        function postPlayerEvent(
          generation,
          request,
          target,
          type,
          values = {},
          allowMissingVideoId = false
        ) {
          if (!target || !isCurrentRequest(generation, request)) return;
          const data = typeof target.getVideoData === "function" ? target.getVideoData() : {};
          const currentVideoId = data && data.video_id ? data.video_id : "";
          if (currentVideoId && currentVideoId !== request.videoId) return;
          if (!currentVideoId && !allowMissingVideoId) return;
          post(type, {
            loadId: request.loadId,
            videoId: currentVideoId || request.videoId,
            ...values
          });
        }

        function applyPlaybackRate(generation, request, target, rate) {
          if (!target || !isCurrentRequest(generation, request)) return;
          if (typeof target.getAvailablePlaybackRates !== "function") return;
          const rates = target.getAvailablePlaybackRates();
          if (rates.includes(rate)) target.setPlaybackRate(rate);
          postPlayerEvent(generation, request, target, "rateChanged", {
            rate: typeof target.getPlaybackRate === "function" ? target.getPlaybackRate() : 1
          });
        }

        function beginRequest(request) {
          if (!apiReady || typeof YT === "undefined" || typeof YT.Player !== "function") {
            pending = request;
            return;
          }

          const generation = ++playerGeneration;
          request.acceptingEvents = false;
          activeRequest = request;
          pending = null;

          const previousPlayer = player;
          player = null;
          if (previousPlayer && typeof previousPlayer.destroy === "function") {
            previousPlayer.destroy();
          }

          const container = document.getElementById("player-container");
          container.replaceChildren();
          const mount = document.createElement("div");
          mount.id = "player-" + generation;
          mount.className = "player-mount";
          container.appendChild(mount);

          player = new YT.Player(mount.id, {
            width: "100%",
            height: "100%",
            playerVars: {
              playsinline: 1,
              controls: 1,
              enablejsapi: 1,
              origin: "__CLIENT_ORIGIN__"
            },
            events: {
              onReady: function(event) {
                if (!isCurrentRequest(generation, request)) return;
                player = event.target;
                const load = request.autoplay ? "loadVideoById" : "cueVideoById";
                event.target[load]({
                  videoId: request.videoId,
                  startSeconds: request.startSeconds || 0
                });
              },
              onStateChange: function(event) {
                if (!isCurrentRequest(generation, request)) return;
                if (event.data === YT.PlayerState.PLAYING) {
                  request.acceptingEvents = true;
                  applyPlaybackRate(
                    generation,
                    request,
                    event.target,
                    request.playbackRate
                  );
                  postPlayerEvent(generation, request, event.target, "playing");
                }
                if (event.data === YT.PlayerState.CUED) {
                  request.acceptingEvents = true;
                  applyPlaybackRate(
                    generation,
                    request,
                    event.target,
                    request.playbackRate
                  );
                  postPlayerEvent(generation, request, event.target, "paused");
                }
                if (request.acceptingEvents) {
                  if (event.data === YT.PlayerState.BUFFERING) {
                    postPlayerEvent(generation, request, event.target, "buffering");
                  }
                  if (event.data === YT.PlayerState.PAUSED) {
                    postPlayerEvent(generation, request, event.target, "paused");
                  }
                  if (event.data === YT.PlayerState.ENDED) {
                    postPlayerEvent(generation, request, event.target, "ended");
                  }
                }
              },
              onError: function(event) {
                // Errors can arrive before getVideoData exposes an ID. The
                // callback's immutable generation still identifies its load.
                postPlayerEvent(
                  generation,
                  request,
                  event.target,
                  "error",
                  { code: event.data },
                  true
                );
              },
              onPlaybackRateChange: function(event) {
                postPlayerEvent(
                  generation,
                  request,
                  event.target,
                  "rateChanged",
                  { rate: event.data }
                );
              },
              onAutoplayBlocked: function(event) {
                postPlayerEvent(
                  generation,
                  request,
                  event.target,
                  "autoplayBlocked"
                );
              }
            }
          });
        }

        function applyPending() {
          if (!pending || !apiReady) return;
          const request = pending;
          beginRequest(request);
        }

        window.onYouTubeIframeAPIReady = function() {
          apiReady = true;
          post("ready");
          applyPending();
          progressTimer = setInterval(function() {
            const generation = playerGeneration;
            const request = activeRequest;
            const target = player;
            if (!target || !request || !isCurrentRequest(generation, request)) return;
            if (typeof target.getCurrentTime !== "function") return;
            if (target.getPlayerState() !== YT.PlayerState.PLAYING) return;
            if (!request.acceptingEvents) return;
            postPlayerEvent(generation, request, target, "progress", {
              position: target.getCurrentTime() || 0,
              duration: target.getDuration() || 0
            });
          }, 1000);
        };

        window.listenLater = {
          load: function(request) {
            pending = request;
            applyPending();
          },
          play: function() {
            if (activeRequest) activeRequest.autoplay = true;
            if (player && typeof player.playVideo === "function") player.playVideo();
          },
          pause: function() {
            if (activeRequest) activeRequest.autoplay = false;
            if (player && typeof player.pauseVideo === "function") player.pauseVideo();
          },
          seek: function(seconds) {
            if (activeRequest) activeRequest.startSeconds = seconds;
            if (player && typeof player.seekTo === "function") player.seekTo(seconds, true);
          },
          setRate: function(rate) {
            if (activeRequest) activeRequest.playbackRate = rate;
            if (activeRequest) {
              applyPlaybackRate(playerGeneration, activeRequest, player, rate);
            }
          }
        };
      </script>
    </body>
    </html>
    """
}
