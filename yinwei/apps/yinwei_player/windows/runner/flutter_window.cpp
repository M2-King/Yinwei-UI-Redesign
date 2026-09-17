#include "flutter_window.h"

#include <cmath>
#include <optional>

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <flutter_windows.h>

#include "flutter/generated_plugin_registrant.h"

namespace {
const flutter::EncodableValue* ValueOrNull(const flutter::EncodableMap& map,
                                           const char* key) {
  auto it = map.find(flutter::EncodableValue(key));
  if (it == map.end()) {
    return nullptr;
  }
  return &(it->second);
}
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
  RegisterWindowChromeChannel();
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::RegisterWindowChromeChannel() {
  window_chrome_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "yinwei/window_chrome",
          &flutter::StandardMethodCodec::GetInstance());

  window_chrome_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() == "setToolWindow") {
          bool enable = false;
          if (const auto* value = std::get_if<bool>(call.arguments())) {
            enable = *value;
          }
          SetToolWindowStyle(enable);
          result->Success();
          return;
        }
        if (call.method_name() == "setIslandHitShape") {
          IslandHitShape shape;
          if (const auto* args =
                  std::get_if<flutter::EncodableMap>(call.arguments())) {
            shape.enabled = false;
            if (const auto* enabled =
                    std::get_if<bool>(ValueOrNull(*args, "enabled"))) {
              shape.enabled = *enabled;
            }
            shape.width = ReadMapDouble(*args, "width", 0);
            shape.height = ReadMapDouble(*args, "height", 0);
            shape.inset_x = ReadMapDouble(*args, "insetX", 0);
            shape.inset_y = ReadMapDouble(*args, "insetY", 0);
            shape.radius = ReadMapDouble(*args, "radius", 0);
          }
          SetIslandHitShape(shape);
          result->Success();
          return;
        }
        if (call.method_name() == "getWorkAreaForWindow") {
          result->Success(GetWorkAreaForWindow());
          return;
        }
        result->NotImplemented();
      });
}

void FlutterWindow::SetToolWindowStyle(bool enable) {
  HWND hwnd = GetHandle();
  if (!hwnd) {
    return;
  }
  LONG_PTR ex = GetWindowLongPtr(hwnd, GWL_EXSTYLE);
  if (enable) {
    ex |= WS_EX_TOOLWINDOW;
    ex &= ~WS_EX_APPWINDOW;
  } else {
    ex &= ~WS_EX_TOOLWINDOW;
    ex |= WS_EX_APPWINDOW;
  }
  SetWindowLongPtr(hwnd, GWL_EXSTYLE, ex);
  // Force taskbar / Alt+Tab membership refresh.
  SetWindowPos(hwnd, nullptr, 0, 0, 0, 0,
               SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_FRAMECHANGED |
                   SWP_NOACTIVATE);
}

void FlutterWindow::SetIslandHitShape(const IslandHitShape& shape) {
  island_hit_shape_ = shape;
  RefreshIslandHitShape();
}

void FlutterWindow::RefreshIslandHitShape() {
  HWND hwnd = GetHandle();
  if (!hwnd) {
    return;
  }
  if (!island_hit_shape_.enabled || island_hit_shape_.width <= 0 ||
      island_hit_shape_.height <= 0) {
    SetWindowRgn(hwnd, nullptr, TRUE);
    return;
  }

  const double scale = DpiScale();
  const int left =
      static_cast<int>(std::lround(island_hit_shape_.inset_x * scale));
  const int top =
      static_cast<int>(std::lround(island_hit_shape_.inset_y * scale));
  const int right = static_cast<int>(std::lround(
                        (island_hit_shape_.width - island_hit_shape_.inset_x) *
                        scale)) +
                    1;
  const int bottom = static_cast<int>(std::lround(
                         (island_hit_shape_.height - island_hit_shape_.inset_y) *
                         scale)) +
                     1;
  int diameter =
      static_cast<int>(std::lround(island_hit_shape_.radius * 2.0 * scale));
  if (diameter < 0) {
    diameter = 0;
  }
  HRGN region =
      CreateRoundRectRgn(left, top, right, bottom, diameter, diameter);
  if (!region) {
    SetWindowRgn(hwnd, nullptr, TRUE);
    return;
  }
  // SetWindowRgn takes ownership of the HRGN.
  SetWindowRgn(hwnd, region, TRUE);
}

flutter::EncodableMap FlutterWindow::GetWorkAreaForWindow() {
  flutter::EncodableMap result;
  HWND hwnd = GetHandle();
  if (!hwnd) {
    result[flutter::EncodableValue("left")] = flutter::EncodableValue(0.0);
    result[flutter::EncodableValue("top")] = flutter::EncodableValue(0.0);
    result[flutter::EncodableValue("width")] = flutter::EncodableValue(0.0);
    result[flutter::EncodableValue("height")] = flutter::EncodableValue(0.0);
    return result;
  }

  HMONITOR monitor = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
  MONITORINFO info;
  info.cbSize = sizeof(MONITORINFO);
  if (!GetMonitorInfo(monitor, &info)) {
    result[flutter::EncodableValue("left")] = flutter::EncodableValue(0.0);
    result[flutter::EncodableValue("top")] = flutter::EncodableValue(0.0);
    result[flutter::EncodableValue("width")] = flutter::EncodableValue(0.0);
    result[flutter::EncodableValue("height")] = flutter::EncodableValue(0.0);
    return result;
  }

  const double scale = DpiScale();
  result[flutter::EncodableValue("left")] =
      flutter::EncodableValue(info.rcWork.left / scale);
  result[flutter::EncodableValue("top")] =
      flutter::EncodableValue(info.rcWork.top / scale);
  result[flutter::EncodableValue("width")] = flutter::EncodableValue(
      (info.rcWork.right - info.rcWork.left) / scale);
  result[flutter::EncodableValue("height")] = flutter::EncodableValue(
      (info.rcWork.bottom - info.rcWork.top) / scale);
  return result;
}

double FlutterWindow::DpiScale() {
  HWND hwnd = GetHandle();
  UINT dpi = 96;
  if (hwnd) {
    HMODULE user32 = GetModuleHandleW(L"user32.dll");
    if (user32) {
      using GetDpiForWindowFn = UINT(WINAPI*)(HWND);
      auto get_dpi_for_window = reinterpret_cast<GetDpiForWindowFn>(
          GetProcAddress(user32, "GetDpiForWindow"));
      if (get_dpi_for_window) {
        dpi = get_dpi_for_window(hwnd);
      }
    }
    if (dpi == 0) {
      HMONITOR monitor = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
      dpi = FlutterDesktopGetDpiForMonitor(monitor);
    }
  }
  if (dpi == 0) {
    dpi = 96;
  }
  return static_cast<double>(dpi) / 96.0;
}

double FlutterWindow::ReadMapDouble(const flutter::EncodableMap& args,
                                    const char* key,
                                    double fallback) {
  const flutter::EncodableValue* value = ValueOrNull(args, key);
  if (const auto* as_double = std::get_if<double>(value)) {
    return *as_double;
  }
  if (const auto* as_int = std::get_if<int32_t>(value)) {
    return static_cast<double>(*as_int);
  }
  if (const auto* as_int64 = std::get_if<int64_t>(value)) {
    return static_cast<double>(*as_int64);
  }
  return fallback;
}

void FlutterWindow::OnDestroy() {
  window_chrome_channel_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
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
    case WM_DPICHANGED: {
      LRESULT handled =
          Win32Window::MessageHandler(hwnd, message, wparam, lparam);
      RefreshIslandHitShape();
      return handled;
    }
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
