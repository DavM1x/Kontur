# Сборка для Windows x64

Нужны PowerShell 7, Rust с Cargo и компоновщиком для Windows x64, компилятор C# из .NET Framework в `%WINDIR%\Microsoft.NET\Framework64\v4.0.30319` и следующие файлы.

| Файл | Источник |
| --- | --- |
| Архив Windows x64 libmpv LGPL с `libmpv-2.dll` и `LICENSE.LGPL` | [Выпуски mpv](https://github.com/mpv-player/mpv/releases) |
| Пакет `Microsoft.Web.WebView2` версии `1.0.3912.50` | [NuGet](https://www.nuget.org/packages/Microsoft.Web.WebView2/1.0.3912.50) |
| Подписанный `MicrosoftEdgeWebview2Setup.exe` | [Microsoft WebView2 Evergreen Bootstrapper](https://developer.microsoft.com/microsoft-edge/webview2/#download-section) |

```powershell
pwsh -File .\setup\Build.ps1 `
  -MpvArchive .\deps\libmpv-x64-lgpl.zip `
  -WebViewSdk .\deps\microsoft.web.webview2.1.0.3912.50.nupkg `
  -WebViewBootstrapper .\deps\MicrosoftEdgeWebview2Setup.exe
```

По умолчанию собираются оба установщика. Параметр `-Edition full` или `-Edition lite` выбирает один выпуск. Готовые EXE появятся в `dist/`. При сборке только Lite достаточно указать `-WebViewSdk`. На чистом компьютере Lite скачивает недостающие компоненты во время установки.

Для выпуска 0.1.0 использован libmpv `v0.42.0-dev-gd11ffba25`. SHA-256 его исходного Windows-архива `A0474D5CD726C77E6D0C280B750A320D943D3960A7D03D61687D387B84F67B43`. Иллюстрации ночной и дневной тем находятся в `assets/`.
