@echo off
REM Builds and starts API + MongoDB with Docker Compose.
cd /d "%~dp0"
docker compose up --build
pause
