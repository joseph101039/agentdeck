.PHONY: build test app install-hooks clean

build:
	swift build -c release

test:
	./test.sh

app:
	./install-app.sh

# Codex ignores hooks until each is trusted; the script trusts AgentDeck's
# through Codex's own app-server, the same way its /hooks screen does.
install-hooks: build
	.build/release/agentdeck-hook install && node tools/trust-codex-hooks.mjs

clean:
	rm -rf .build
