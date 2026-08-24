# AI Live Translator

AI Live Translator is a realtime speech transcription, translation and AI voice system for Web and Mobile.

## Project Status

Current Phase:

**Phase 0 - Project Initialization & Technical Baseline**

## Architecture

The project follows a monorepo structure containing:

- Flutter Mobile Application
- Next.js Web Application
- FastAPI Backend
- Background Worker
- PostgreSQL
- Redis
- Object Storage
- AI Provider Integration

## Repository Structure

```text
apps/
  mobile/
  web/

services/
  api/
  worker/

infra/
  docker/
  nginx/
  scripts/

docs/
  architecture/
  api/
  benchmark/
  decisions/
  research/

test-data/
  audio/
  
Development Roadmap

P0 - Discovery / Project Initialization
P1 - Technical Spike
P2 - Transcribe MVP
P3 - Translation
P4 - Sharing / Multi-user
P5 - TTS / Dubbing
P6 - Recording / Export
P7 - Organization / Dictionary
P8 - Billing / Admin
P9 - Hardening / Beta
P10 - Integrations
