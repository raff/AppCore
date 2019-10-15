#pragma once
#include <AppCore/App.h>
#include <AppCore/Window.h>
#include "RefCountedImpl.h"
#include "MonitorMac.h"
#include <memory>

namespace ultralight {
    
class AppMac;
class GPUContextMetal;
class FileSystemMac;
    
class AppMac : public App,
               public RefCountedImpl<AppMac>,
               public WindowListener {
public:
  // Inherited from WindowListener

  virtual void OnClose() override;

  virtual void OnResize(uint32_t width, uint32_t height) override;

  // Inherited from App
                   
  virtual const Settings& settings() const override { return settings_; }

  virtual void set_listener(AppListener* listener) override { listener_ = listener; }

  virtual void set_window(Ref<Window> window) override;

  virtual RefPtr<Window> window() override { return window_; }

  virtual AppListener* listener() override { return listener_; }

  virtual bool is_running() const override { return is_running_; }

  virtual Monitor* main_monitor() override;

  virtual Ref<Renderer> renderer() override;

  virtual void Run() override;

  virtual void Quit() override;

  REF_COUNTED_IMPL(AppMac);
                   
  void Update();

protected:
  AppMac(Settings settings, Config config);
  virtual ~AppMac();

  friend class App;
  
  DISALLOW_COPY_AND_ASSIGN(AppMac);

  bool is_running_ = false;
  Settings settings_;
  AppListener* listener_ = nullptr;
  RefPtr<Renderer> renderer_;
  RefPtr<Window> window_;
  MonitorMac main_monitor_;
  bool config_force_repaint_ = false;
  bool is_forcing_next_two_repaints_ = false;
  int repaint_count_ = 0;
  std::unique_ptr<GPUContextMetal> gpu_context_;
  std::unique_ptr<FileSystemMac> file_system_;
};
    
    
}  // namespace ultralight
