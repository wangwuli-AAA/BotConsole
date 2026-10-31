#include "flutter_window.h"

#include <optional>
#include <flutter/method_result_functions.h>
#include <flutter/standard_method_codec.h>

#include "flutter/generated_plugin_registrant.h"
#include "resource.h"

namespace {
constexpr UINT kTrayMessage = WM_APP + 1;
constexpr UINT kExitApproved = WM_APP + 2;
constexpr UINT kShowWindow = 1;
constexpr UINT kExit = 2;
}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());
  tray_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "bot_console/tray",
          &flutter::StandardMethodCodec::GetInstance());
  AddTrayIcon();

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (tray_registered_) {
    Shell_NotifyIconW(NIM_DELETE, &tray_icon_);
    tray_registered_ = false;
  }
  tray_channel_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

bool FlutterWindow::AddTrayIcon() {
  tray_icon_ = {};
  tray_icon_.cbSize = sizeof(tray_icon_);
  tray_icon_.hWnd = GetHandle();
  tray_icon_.uID = 1;
  tray_icon_.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP | NIF_SHOWTIP;
  tray_icon_.uCallbackMessage = kTrayMessage;
  tray_icon_.hIcon = LoadIconW(GetModuleHandle(nullptr),
                             MAKEINTRESOURCEW(IDI_APP_ICON));
  wcscpy_s(tray_icon_.szTip, L"BotConsole - SnowLuma / MaiBot");
  tray_registered_ = Shell_NotifyIconW(NIM_ADD, &tray_icon_) != FALSE;
  if (tray_registered_) {
    tray_icon_.uVersion = NOTIFYICON_VERSION_4;
    Shell_NotifyIconW(NIM_SETVERSION, &tray_icon_);
  }
  return tray_registered_;
}

void FlutterWindow::RestoreFromTray() {
  ShowWindow(GetHandle(), IsIconic(GetHandle()) ? SW_RESTORE : SW_SHOW);
  SetForegroundWindow(GetHandle());
  if (tray_channel_) {
    tray_channel_->InvokeMethod("visibilityChanged",
        std::make_unique<flutter::EncodableValue>(true));
  }
}

void FlutterWindow::ShowTrayMenu() {
  HMENU menu = CreatePopupMenu();
  if (!menu) return;
  AppendMenuW(menu, MF_STRING, kShowWindow, L"\u663e\u793a\u7a97\u53e3");
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  AppendMenuW(menu, MF_STRING | (exit_pending_ ? MF_GRAYED : 0), kExit,
              L"\u9000\u51fa");
  POINT cursor;
  GetCursorPos(&cursor);
  SetForegroundWindow(GetHandle());
  const UINT command = TrackPopupMenu(
      menu, TPM_RETURNCMD | TPM_RIGHTBUTTON, cursor.x, cursor.y, 0,
      GetHandle(), nullptr);
  DestroyMenu(menu);
  PostMessageW(GetHandle(), WM_NULL, 0, 0);
  if (command == kShowWindow) RestoreFromTray();
  if (command == kExit) RequestTrayExit();
}

void FlutterWindow::RequestTrayExit() {
  if (exit_pending_ || !tray_channel_) return;
  exit_pending_ = true;
  RestoreFromTray();
  tray_channel_->InvokeMethod(
      "requestExit", nullptr,
      std::make_unique<flutter::MethodResultFunctions<flutter::EncodableValue>>(
          [this](const flutter::EncodableValue* result) {
            const auto* approved = result ? std::get_if<bool>(result) : nullptr;
            if (approved && *approved) {
              // Destroy after returning from the engine's reply callback.
              PostMessageW(GetHandle(), kExitApproved, 0, 0);
            } else {
              exit_pending_ = false;
            }
          },
          [this](const std::string&, const std::string&,
                 const flutter::EncodableValue*) { exit_pending_ = false; },
          [this]() { exit_pending_ = false; }));
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (message == taskbar_created_) {
    // Explorer restarts remove notification icons; never strand a hidden window.
    if (!AddTrayIcon()) RestoreFromTray();
    return 0;
  }
  if (message == kTrayMessage) {
    switch (LOWORD(lparam)) {
      case NIN_SELECT:
      case NIN_KEYSELECT:
      case WM_LBUTTONDBLCLK:
        RestoreFromTray();
        break;
      case WM_CONTEXTMENU:
      case WM_RBUTTONUP:
        ShowTrayMenu();
        break;
    }
    return 0;
  }
  if (message == kExitApproved) {
    Destroy();
    return 0;
  }
  if (tray_registered_ &&
      (message == WM_CLOSE ||
       (message == WM_SYSCOMMAND && (wparam & 0xFFF0) == SC_MINIMIZE) ||
       (message == WM_SIZE && wparam == SIZE_MINIMIZED))) {
    if (!exit_pending_) {
      ShowWindow(hwnd, SW_HIDE);
      if (tray_channel_) {
        tray_channel_->InvokeMethod("visibilityChanged",
            std::make_unique<flutter::EncodableValue>(false));
      }
    }
    return 0;
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
