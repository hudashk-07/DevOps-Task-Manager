@echo off
REM Starts MongoDB (Docker) + the API on your PC with Node.js.
cd /d "%~dp0"
if not exist .env copy .env.example .env >nul
if not exist node_modules call npm install
docker compose -f docker-compose.yml -f docker-compose.dev.yml up -d mongo
if errorlevel 1 (
  echo Could not start MongoDB. Is Docker Desktop running?
  pause
  exit /b 1
)
echo Open http://localhost:5000 in your browser. Press Ctrl+C to stop.
call npm run start:local
