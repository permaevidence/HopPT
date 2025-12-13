# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

HopPT is an iOS chat client that connects to user-configured OpenAI-compatible LLM endpoints (local or remote). Key features:
- Multi-endpoint management with per-endpoint model selection
- Streaming chat with SSE-style responses
- Web search pipeline with local scraping and RAG
- On-device voice transcription via WhisperKit
- Voice-only mode with iOS TTS

## Build Commands

```bash
# Build for iOS Simulator
xcodebuild -project HopPT/HopPT.xcodeproj -scheme HopPT \
  -destination 'platform=iOS Simulator,name=iPhone 16' build

# Run tests
xcodebuild -project HopPT/HopPT.xcodeproj -scheme HopPT \
  -destination 'platform=iOS Simulator,name=iPhone 16' test
```

## Project Structure

```
HopPT/
├── HopPT.xcodeproj/          # Xcode project (SPM deps: WhisperKit, MarkdownUI)
└── HopPT/
    ├── App/                  # App entry point, settings
    │   ├── HopPTApp.swift
    │   └── AppSettings.swift
    ├── Models/               # Data models
    │   ├── EndpointConfig.swift
    │   ├── Attachment.swift
    │   └── CoreDataModels.swift
    ├── ViewModels/
    │   └── ChatViewModel.swift
    ├── Services/             # Backend services
    │   ├── LMStudioService.swift    # Streaming HTTP to LLM
    │   ├── ModelListClient.swift    # Fetch available models
    │   ├── Transcription.swift      # WhisperKit integration
    │   ├── TTSManager.swift         # iOS TTS
    │   ├── WebRAG.swift             # NaturalLanguage embeddings
    │   └── WebSearchPipeline.swift  # Serper API + scraping
    ├── Utilities/
    │   ├── DeviceSupport.swift
    │   └── KeychainHelper.swift
    └── Views/
        ├── Chat/             # Chat UI
        ├── Settings/         # Settings screens
        └── Components/       # Reusable UI components
```

## Key Patterns

### Endpoint Configuration
Endpoints are stored in `AppSettings.endpoints` array. API keys are stored in iOS Keychain (not UserDefaults). The active endpoint syncs to bridge fields (`apiBase`, `apiKey`, `model`) that the rest of the app uses.

### Web Search Pipeline Flow
1. `generateQueries()` - LLM generates up to 4 search queries + standalone question
2. `fetchWebContext()` - Parallel Serper searches, dedupe results
3. `refineContextIfNeeded()` - Loop: assess coverage -> scrape URLs -> apply RAG -> merge results
4. `messagesForSecondStage()` - Build final prompt with web context for streaming response

### Local Scraping
`PageToPDFRenderer` uses WKWebView to render pages, handles cookie consent popups (CMPBlocker), scrolls to trigger lazy loading, creates paginated PDFs, then extracts text via PDFKit.

### RAG Processing
Large scraped documents (>=4000 chars) get chunked with overlap. Chunks are scored against a focus query using NLEmbedding sentence vectors. Top-k chunks are kept; full text is discarded to manage context size.

## External Dependencies

- **serper.dev**: Web search API (requires API key in Settings)
- **Jina Reader**: Optional alternative scraping via `r.jina.ai` (requires API key)
- **WhisperKit**: On-device transcription (downloads ~632MB model from HuggingFace)

## API Compatibility

Works with any endpoint exposing:
- `POST {apiBase}/chat/completions` (streaming supported)
- `GET {apiBase}/models`
- Ollama: `GET {host}/api/tags`

Base URL should include `/v1` if the server expects `/v1/chat/completions`.

## Voice Requirements

WhisperKit transcription requires iPhone 13 generation or newer (checked via `DeviceSupport.isIPhone13OrNewer`).

## Getting Started

1. Open `HopPT/HopPT.xcodeproj` in Xcode 16+
2. Change the Team ID in Signing & Capabilities
3. Build and run on device or simulator
