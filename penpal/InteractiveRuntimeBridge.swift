import Foundation

enum InteractiveRuntimeBridge {
    static func javaScript(domains: [String], capabilities: [String]) -> String {
        let domainJSON = json(domains)
        let capabilityJSON = json(capabilities)
        return """
        (() => {
          const allowedDomains = new Set(\(domainJSON));
          const allowedCapabilities = new Set(\(capabilityJSON));
          const pending = new Map();
          const asked = new Set();
          const reported = new Set();
          let nextID = 1;
          let reportCount = 0;

          function post(type, value, reason) {
            const id = `runtime-${Date.now()}-${nextID++}`;
            return new Promise((resolve, reject) => {
              pending.set(id, { resolve, reject });
              window.webkit.messageHandlers.penpalRuntime.postMessage({
                id, type, value, reason: String(reason || '').slice(0, 160)
              });
            });
          }

          window.__penpalRuntimeResolve = (id, granted, error) => {
            const item = pending.get(id);
            if (!item) return;
            pending.delete(id);
            if (granted) item.resolve(true);
            else item.reject(new DOMException(error || 'Permission denied', 'NotAllowedError'));
          };

          const runtime = {
            domains: Object.freeze(Array.from(allowedDomains)),
            capabilities: Object.freeze(Array.from(allowedCapabilities)),
            hasDomain(host) {
              return allowedDomains.has(String(host || '').toLowerCase());
            },
            hasCapability(id) {
              return allowedCapabilities.has(String(id || '').toLowerCase());
            },
            async requestDomain(host, reason) {
              host = String(host || '').toLowerCase();
              if (allowedDomains.has(host)) return true;
              const granted = await post('domain', host, reason);
              if (granted) allowedDomains.add(host);
              return granted;
            },
            async requestCapability(id, reason) {
              id = String(id || '').toLowerCase();
              if (allowedCapabilities.has(id)) return true;
              const granted = await post('capability', id, reason);
              if (granted) allowedCapabilities.add(id);
              return granted;
            },
            restart() {
              window.location.reload();
            }
          };
          Object.defineProperty(window, 'penpal', {
            value: Object.freeze({ runtime: Object.freeze(runtime) }),
            configurable: false,
            writable: false
          });

          try {
            const media = navigator.mediaDevices;
            const originalGetUserMedia = media && media.getUserMedia
              ? media.getUserMedia.bind(media) : null;
            if (originalGetUserMedia) {
              media.getUserMedia = async constraints => {
                if (constraints && constraints.video) {
                  await runtime.requestCapability('camera', 'Use video in this block');
                }
                if (constraints && constraints.audio) {
                  await runtime.requestCapability('microphone', 'Use audio in this block');
                }
                return originalGetUserMedia(constraints);
              };
            }
          } catch (_) {}

          try {
            const clipboard = navigator.clipboard;
            if (clipboard && clipboard.readText) {
              const readText = clipboard.readText.bind(clipboard);
              clipboard.readText = async () => {
                await runtime.requestCapability('clipboard.read', 'Read clipboard text');
                return readText();
              };
            }
            if (clipboard && clipboard.writeText) {
              const writeText = clipboard.writeText.bind(clipboard);
              clipboard.writeText = async value => {
                await runtime.requestCapability('clipboard.write', 'Copy text from this block');
                return writeText(value);
              };
            }
          } catch (_) {}

          try {
            const geo = navigator.geolocation;
            if (geo && geo.getCurrentPosition) {
              const getPosition = geo.getCurrentPosition.bind(geo);
              geo.getCurrentPosition = (success, failure, options) => {
                runtime.requestCapability('location', 'Use location in this block')
                  .then(() => getPosition(success, failure, options))
                  .catch(error => { if (failure) failure(error); });
              };
            }
          } catch (_) {}

          document.addEventListener('securitypolicyviolation', event => {
            try {
              const url = new URL(event.blockedURI);
              if (url.protocol !== 'https:' && url.protocol !== 'wss:') return;
              const host = url.hostname.toLowerCase();
              if (!host || allowedDomains.has(host) || asked.has(host)) return;
              asked.add(host);
              runtime.requestDomain(
                host,
                `Allow a resource blocked by ${event.violatedDirective}`
              ).catch(() => {});
            } catch (_) {}
          });

          function cleanSource(value) {
            try {
              const url = new URL(String(value || ''), location.href);
              if (url.protocol === 'http:' || url.protocol === 'https:') {
                return `${url.origin}${url.pathname}`.slice(0, 300);
              }
            } catch (_) {}
            return String(value || '').split('?')[0].slice(0, 300);
          }

          function report(kind, message, source, line, column) {
            if (reportCount >= 8) return;
            message = String(message || 'Unknown runtime failure')
              .replace(/https?:\\/\\/[^\\s"'<>]+/g, value => cleanSource(value))
              .slice(0, 400);
            const diagnostic = {
              kind: String(kind || 'runtime').slice(0, 40),
              message,
              source: cleanSource(source),
              line: Number.isFinite(Number(line)) ? Number(line) : null,
              column: Number.isFinite(Number(column)) ? Number(column) : null
            };
            const fingerprint = `${diagnostic.kind}|${diagnostic.message}|${diagnostic.source}|${diagnostic.line}`;
            if (reported.has(fingerprint)) return;
            reported.add(fingerprint);
            reportCount += 1;
            try {
              window.webkit.messageHandlers.penpalRuntime.postMessage({
                type: 'diagnostic',
                value: JSON.stringify(diagnostic)
              });
            } catch (_) {}
          }

          function safeExceptionMessage(error, fallback) {
            const name = error && error.name ? String(error.name) : 'Error';
            const technical = new Set([
              'ReferenceError', 'TypeError', 'SyntaxError', 'RangeError',
              'URIError', 'EvalError', 'CompileError', 'LinkError', 'RuntimeError'
            ]);
            if (!technical.has(name)) return `${name}: ${fallback}`;
            return `${name}: ${String(error && error.message || fallback)}`;
          }

          window.addEventListener('error', event => {
            const target = event.target;
            if (target && target !== window) {
              const source = target.src || target.href || '';
              report(
                'resource',
                `Failed to load ${String(target.tagName || 'resource').toLowerCase()}`,
                source,
                null,
                null
              );
              return;
            }
            report(
              'javascript',
              safeExceptionMessage(event.error, event.message || 'Runtime exception'),
              event.filename,
              event.lineno,
              event.colno
            );
          }, true);

          window.addEventListener('unhandledrejection', event => {
            const reason = event.reason;
            const name = reason && reason.name ? String(reason.name) : '';
            if (name === 'NotAllowedError' || name === 'AbortError') return;
            report(
              'promise',
              safeExceptionMessage(reason, 'Unhandled promise rejection'),
              '',
              null,
              null
            );
          });

          setInterval(() => {
            try {
              window.webkit.messageHandlers.penpalRuntime.postMessage({
                type: 'heartbeat', value: String(Date.now())
              });
            } catch (_) {}
          }, 2000);
        })();
        """
    }

    private static func json(_ values: [String]) -> String {
        guard let data = try? JSONEncoder().encode(values),
              let string = String(data: data, encoding: .utf8) else { return "[]" }
        return string
    }
}
