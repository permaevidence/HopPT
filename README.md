# HopPT (iOS)

A **bring-your-own-endpoint** chat client for iOS that lets you talk to *your* LLMs (local or remote) through an OpenAI-compatible API — with **streaming**, **multi-endpoint + model management**, **web search with on-device scraping**, **local RAG to keep context light**, and **fully on-device voice input + TTS voice-only mode**.

> ✅ You configure the endpoints.  
> ✅ Chats are stored locally on-device.  
> ✅ API keys are stored in the iOS Keychain.

---

## Features

### 🔌 Bring Your Own LLM Endpoint
- Add one or more endpoints (local or hosted).
- Each endpoint can have its own:
  - Base URL
  - API key (optional)
  - Selected models + preferred model
- **Model picker** in the chat toolbar to switch quickly.

Works best with endpoints that expose:
- `POST {apiBase}/chat/completions` (streaming supported)
- `GET  {apiBase}/models`  
…and it also supports Ollama model discovery via:
- `GET {host}/api/tags`

> Tip: If your server expects `/v1/chat/completions`, set your base URL to include `/v1` (e.g. `http://192.168.1.10:1234/v1`).

---

### 💬 Streaming Chat + Cancel
- Server-Sent Events style streaming.
- “Stop” cancels the in-flight request immediately.
- Filters common “thinking” tags (`<think>…</think>`, etc.) so the UI stays clean.

---

### 🧠 Persistent Conversations (Local)
- Conversations/messages stored locally using Core Data.
- Fast conversation switching and deletion.
- “Danger Zone” option to delete all conversations.

---

### 🌐 Web Search + Local Scraping + Local RAG
A built-in pipeline designed to keep answers strong **without blowing up the context window**.

**How it works:**
1. The app generates focused search queries.
2. It uses **serper.dev** to retrieve search results (you provide the API key).
3. It scrapes selected URLs using one of two modes:
   - **Local (WebKit → PDF → PDFKit text extraction)** *(default / offline-ish approach)*  
     Renders the page on-device in a non-persistent WKWebView, prints it to PDF, then extracts text with PDFKit. Surprisingly effective for real-world pages.
   - **Jina Reader (API)** *(optional)*  
     Faster / higher quality extraction for some sites. Requires a Jina key if you enable it.
4. For large pages, a **local RAG** step runs on-device using Apple’s `NaturalLanguage` sentence embeddings:
   - Splits large documents into overlapping chunks
   - Scores relevance vs. a per-page “focus query”
   - Sends only the top chunks onward

Result: you can consult many sources without dumping huge raw page bodies into your prompt.

---

### 🎙️ On-Device Transcription (WhisperKit)
- Optional voice input using a strong local Whisper model:
  - `whisper-large-v3-turbo` (downloaded on-device)
- **One-time compilation per app update**:
  - Compilation can take a while, but you only do it once after installing/updating the app (or after deleting the model).
- Important note on memory:
  - The **compiled model is stored on disk** and **does not permanently occupy RAM**.
  - RAM usage is primarily during active transcription.

> Voice input is gated to **iPhone 13 generation or newer** (device capability check).

---

### 🔈 Voice-Only Mode (iOS TTS)
A bonus mode that turns the app into a more voice-first assistant:
- Uses iOS **Text-to-Speech** to read assistant replies.
- UI switches to a minimal “voice canvas” experience.
- For best quality: install **Enhanced/Premium iOS voices** in Settings.

---

## Requirements

- Xcode (recent recommended)
- iOS device or simulator for basic chat
- **Voice Input (Whisper)**: iPhone 13 generation or newer (and enough free storage for the model download)

---
