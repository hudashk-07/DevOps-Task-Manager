@echo off
REM Builds the image inside Minikube and deploys everything to Kubernetes.
cd /d "%~dp0"
minikube status >nul 2>&1 || minikube start --driver=docker
if errorlevel 1 goto :fail
for /f "tokens=*" %%i in ('minikube docker-env --shell cmd') do %%i
docker build -t devops-task-manager:1.0 .
if errorlevel 1 goto :fail
kubectl apply -f k8s/namespace.yaml
call :ensure_secret
if errorlevel 1 goto :fail
kubectl apply -f k8s/
if errorlevel 1 goto :fail
kubectl rollout status deployment/mongodb -n devops-task-manager --timeout=180s
kubectl rollout status deployment/task-manager-api -n devops-task-manager --timeout=180s
echo.
echo Opening the app (keep this window open)...
minikube service task-manager-api -n devops-task-manager
goto :eof
:fail
echo Failed. Make sure Docker Desktop is running.
pause
exit /b 1

:ensure_secret
REM Create the MongoDB Secret with a random password only if it does not exist yet.
REM (Never overwritten: MongoDB reads the root password only when its volume is first created.)
kubectl get secret task-manager-secret -n devops-task-manager >nul 2>&1
if not errorlevel 1 exit /b 0
for /f %%p in ('powershell -NoProfile -Command "-join ((48..57)+(97..102) | Get-Random -Count 32 | ForEach-Object {[char]$_})"') do set "MONGO_PW=%%p"
if not defined MONGO_PW exit /b 1
> "%TEMP%\tm-secret.env" echo MONGO_USERNAME=admin
>> "%TEMP%\tm-secret.env" echo MONGO_PASSWORD=%MONGO_PW%
kubectl create secret generic task-manager-secret -n devops-task-manager --from-env-file="%TEMP%\tm-secret.env"
set "RC=%errorlevel%"
del "%TEMP%\tm-secret.env" >nul 2>&1
set "MONGO_PW="
exit /b %RC%
