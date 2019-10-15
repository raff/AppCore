#import "GPUContextMetal.h"
#import "GPUDriverMetal.h"
#include "../../../shaders/metal/bin/metal_shader.h"
#import <dispatch/dispatch.h>
#include <memory>
#include <functional>
#include <AppCore/App.h>
#include <Ultralight/platform/Platform.h>
#include <Ultralight/platform/Config.h>
#include <Ultralight/platform/FileSystem.h>

namespace ultralight {
    
// Public domain from https://stackoverflow.com/a/27952689
inline size_t hash_combine( size_t lhs, size_t rhs ) {
#if defined(__x86_64__)
    lhs ^= rhs + 0x9e3779b97f4a7c15 + (lhs << 6) + (lhs >> 2);
#else
    lhs ^= rhs + 0x9e3779b9 + (lhs << 6) + (lhs >> 2);
#endif
    return lhs;
}
    
RenderState::RenderState() : shader_type(kShaderType_Fill),
                             blend_enabled(true),
                             pixel_format(MTLPixelFormatBGRA8Unorm_sRGB),
                             sample_count(1) {}

size_t RenderState::Hash() {
    size_t result = std::hash<uint32_t>{}((uint32_t)shader_type);
    result = hash_combine(result, std::hash<bool>{}(blend_enabled));
    result = hash_combine(result, std::hash<uint32_t>{}((uint32_t)pixel_format));
    result = hash_combine(result, std::hash<uint32_t>{}((uint32_t)sample_count));
    return result;
}

GPUContextMetal::GPUContextMetal(MTKView* view, int screen_width, int screen_height, double screen_scale, bool fullscreen, bool enable_vsync, bool enable_msaa) {
    device_ = view.device;
    view_ = view;
    msaa_enabled_ = enable_msaa;
    
    set_screen_size(screen_width, screen_height);
    set_scale(screen_scale);
    
    // Load all the shader files with a .metal file extension in the project
    //id<MTLLibrary> defaultLibrary = [device_ newDefaultLibrary];
    
    if (App::instance()->settings().load_shaders_from_file_system) {
        auto fs = ultralight::Platform::instance().file_system();
        if (!fs) {
            NSAlert *alert = [[NSAlert alloc] init];
            [alert setMessageText:@"Could not load shaders, null FileSystem instance."];
            [alert runModal];
            exit(-1);
        }
        ultralight::FileHandle handle = fs->OpenFile("shaders/metal/src/Shaders.metal", false);
        
        if (handle == ultralight::invalidFileHandle) {
            NSAlert *alert = [[NSAlert alloc] init];
            [alert setMessageText:@"Could not load shaders, 'shaders/metal/src/Shaders.metal' not found in FileSystem."];
            [alert runModal];
            exit(-1);
        }
        
        int64_t file_size = 0;
        fs->GetFileSize(handle, file_size);
        std::unique_ptr<char[]> buffer(new char[file_size + 1]);
        fs->ReadFromFile(handle, buffer.get(), file_size);
        buffer[file_size] = '\0';
        fs->CloseFile(handle);
        
        NSError* compileError;
        library_ = [device_ newLibraryWithSource:[NSString stringWithUTF8String:buffer.get()] options:nil error:&compileError];
        if (!library_) {
            NSLog(@"Could not compile shader: %@", compileError);
            NSAlert *alert = [[NSAlert alloc] init];
            [alert setMessageText:@"Could not compile shader."];
            [alert runModal];
            exit(-1);
        }
    } else {
        dispatch_data_t data = dispatch_data_create(metal_shader, metal_shader_len, NULL, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
        library_ = [device_ newLibraryWithData:data error:nil];
    }
    
    // Create the command queue
    command_queue_ = [device_ newCommandQueue];
    
    MTLCaptureManager *sharedCaptureManager = [MTLCaptureManager sharedCaptureManager];
    id<MTLCaptureScope> myCaptureScope = [sharedCaptureManager newCaptureScopeWithDevice:device_];
    myCaptureScope.label = @"Draw Ultralight Frame";
    sharedCaptureManager.defaultCaptureScope = myCaptureScope;
    
    driver_.reset(new ultralight::GPUDriverMetal(this));
}
    
GPUContextMetal::~GPUContextMetal() {
}

void GPUContextMetal::BeginDrawing() {
    MTLCaptureManager *sharedCaptureManager = [MTLCaptureManager sharedCaptureManager];
    
    [sharedCaptureManager.defaultCaptureScope beginScope];
    
    // Create a new command buffer for each render pass to the current drawable
    command_buffer_ = [command_queue_ commandBuffer];
    command_buffer_.label = @"UltralightCommandBuffer";
}
    
void GPUContextMetal::EndDrawing() {
    if (!command_buffer_)
        return;
    
    driver_->EndDrawing();
    
    [command_buffer_ commit];
    [command_buffer_ waitUntilScheduled];
    command_buffer_ = nullptr;
    
    MTLCaptureManager *sharedCaptureManager = [MTLCaptureManager sharedCaptureManager];
    [sharedCaptureManager.defaultCaptureScope endScope];
}
    
void GPUContextMetal::PresentFrame() {
    if (view_.currentDrawable)
        [view_.currentDrawable present];
}
    
void GPUContextMetal::Resize(int width, int height) {
    set_screen_size(width, height);
}
    
id<MTLRenderPipelineState> GPUContextMetal::render_pipeline_state() {
    uint32_t hash = render_state_.Hash();
    
    auto i = render_pipeline_states_.find(hash);
    if (i != render_pipeline_states_.end())
        return i->second;
    
    // RenderPipelineState hasn't yet been created for this RenderState permutation. Create it now.
        
    MTLRenderPipelineDescriptor *pipelineStateDescriptor = [[MTLRenderPipelineDescriptor alloc] init];
    pipelineStateDescriptor.label = @"Ultralight RenderPipelineState";
    if (render_state_.shader_type == kShaderType_Fill) {
        pipelineStateDescriptor.vertexFunction = [library_ newFunctionWithName:@"vertexShader"];
        pipelineStateDescriptor.fragmentFunction = [library_ newFunctionWithName:@"fragmentShader"];
    } else if (render_state_.shader_type == kShaderType_FillPath) {
        pipelineStateDescriptor.vertexFunction = [library_ newFunctionWithName:@"pathVertexShader"];
        pipelineStateDescriptor.fragmentFunction = [library_ newFunctionWithName:@"pathFragmentShader"];
    } else {
        NSLog(@"Failed to create pipeline state, unhandled shader type");
        NSAlert *alert = [[NSAlert alloc] init];
        [alert setMessageText:@"Failed to create pipeline state, unhandled shader type"];
        [alert runModal];
        exit(-1);
    }
    
    pipelineStateDescriptor.sampleCount = render_state_.sample_count;
    pipelineStateDescriptor.colorAttachments[0].pixelFormat = render_state_.pixel_format;
    
    auto colorAttachmentDesc = pipelineStateDescriptor.colorAttachments[0];
    colorAttachmentDesc.blendingEnabled = render_state_.blend_enabled;
    colorAttachmentDesc.rgbBlendOperation = MTLBlendOperationAdd;
    colorAttachmentDesc.alphaBlendOperation = MTLBlendOperationAdd;
    colorAttachmentDesc.sourceRGBBlendFactor = MTLBlendFactorOne;
    colorAttachmentDesc.destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    colorAttachmentDesc.sourceAlphaBlendFactor = MTLBlendFactorOneMinusDestinationAlpha;
    colorAttachmentDesc.destinationAlphaBlendFactor = MTLBlendFactorOne;
    
    NSError *error = NULL;
    id<MTLRenderPipelineState> result = [device_ newRenderPipelineStateWithDescriptor:pipelineStateDescriptor
                                                                                error:&error];
    if (!result)
    {
        // Pipeline State creation could fail if we haven't properly set up our pipeline descriptor.
        //  If the Metal API validation is enabled, we can find out more information about what
        //  went wrong.  (Metal API validation is enabled by default when a debug build is run
        //  from Xcode)
        NSLog(@"Failed to create pipeline state, error %@", error);
        NSAlert *alert = [[NSAlert alloc] init];
        [alert setMessageText:@"Failed to create pipeline state."];
        [alert runModal];
        exit(-1);
    }
    
    render_pipeline_states_[hash] = result;
    return result;
}
    
}  // namespace ultralight
