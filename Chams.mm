// File: Chams.mm
// Architecture: arm64 (iOS)
// Framework: Metal, Foundation, UIKit

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static id<MTLDepthStencilState> g_WallhackDepthState = nil;

// Оригинальные указатели на методы Metal
static void (*orig_setDepthStencilState)(id, SEL, id<MTLDepthStencilState>) = NULL;
static void (*orig_drawIndexedPrimitives)(id, SEL, MTLPrimitiveType, NSUInteger, MTLIndexType, id<MTLBuffer>, NSUInteger) = NULL;

// Храним текущее состояние глубины, которое хотела поставить сама игра
static __thread id<MTLDepthStencilState> currentGameDepthState = nil;

// Перехват установки глубины
void hooked_setDepthStencilState(id self, SEL _cmd, id<MTLDepthStencilState> state) {
    currentGameDepthState = state;
    if (orig_setDepthStencilState) {
        orig_setDepthStencilState(self, _cmd, state);
    }
}

// Перехват отрисовки 3D-моделей (полигонов)
void hooked_drawIndexedPrimitives(id self, SEL _cmd, MTLPrimitiveType primitiveType, NSUInteger indexCount, MTLIndexType indexType, id<MTLBuffer> indexBuffer, NSUInteger indexBufferOffset) {
    
    // В Standoff 2 (Unity) скины игроков имеют определенное количество индексов (полигонов).
    // Диапазон от 1200 до 16000 отсекает стены, небо и мелкий мусор, оставляя модели игроков и оружия.
    if (primitiveType == MTLPrimitiveTypeTriangle && indexCount > 1200 && indexCount < 16000) {
        
        // Создаем кастомное состояние глубины "Рисовать сквозь стены" один раз
        if (g_WallhackDepthState == nil) {
            id<MTLDevice> device = [self performSelector:@selector(device)];
            if (device) {
                MTLDepthStencilDescriptor *desc = [[MTLDepthStencilDescriptor alloc] init];
                // Always = пиксели модели всегда выигрывают проверку глубины и рисуются поверх стен
                desc.depthCompareFunction = MTLCompareFunctionAlways;
                desc.depthWriteEnabled = NO;
                g_WallhackDepthState = [device newDepthStencilStateWithDescriptor:desc];
            }
        }
        
        // Если состояние создано, подменяем его перед отрисовкой модели игрока
        if (g_WallhackDepthState != nil && orig_setDepthStencilState != NULL) {
            orig_setDepthStencilState(self, @selector(setDepthStencilState:), g_WallhackDepthState);
            
            // Рисуем модель игрока поверх стены
            orig_drawIndexedPrimitives(self, _cmd, primitiveType, indexCount, indexType, indexBuffer, indexBufferOffset);
            
            // Возвращаем стандартную глубину игры обратно, чтобы стены не ломались
            if (currentGameDepthState != nil) {
                orig_setDepthStencilState(self, @selector(setDepthStencilState:), currentGameDepthState);
            }
            return;
        }
    }
    
    // Обычная отрисовка для всего остального мира (карты, коробок, интерфейса)
    if (orig_drawIndexedPrimitives) {
        orig_drawIndexedPrimitives(self, _cmd, primitiveType, indexCount, indexType, indexBuffer, indexBufferOffset);
    }
}

// Функция подмены методов в таблице Objective-C (Method Swizzling)
void swizzleMetalRenderEncoder() {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) return;
    
    // Создаем пустой буфер и рендер-энкодер, чтобы узнать реальный внутренний класс драйвера Apple GPU
    id<MTLCommandQueue> queue = [device newCommandQueue];
    id<MTLCommandBuffer> buffer = [queue commandBuffer];
    
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    MTLTextureDescriptor *texDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:16 height:16 mipmapped:NO];
    texDesc.usage = MTLTextureUsageRenderTarget;
    id<MTLTexture> dummyTex = [device newTextureWithDescriptor:texDesc];
    pass.colorAttachments[0].texture = dummyTex;
    
    id<MTLRenderCommandEncoder> encoder = [buffer renderCommandEncoderWithDescriptor:pass];
    Class encoderClass = [encoder class];
    [encoder endEncoding];
    
    // Перехватываем setDepthStencilState:
    Method depthMethod = class_getInstanceMethod(encoderClass, @selector(setDepthStencilState:));
    if (depthMethod) {
        orig_setDepthStencilState = (void *)method_getImplementation(depthMethod);
        method_setImplementation(depthMethod, (IMP)hooked_setDepthStencilState);
    }
    
    // Перехватываем drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:
    SEL drawSel = @selector(drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:);
    Method drawMethod = class_getInstanceMethod(encoderClass, drawSel);
    if (drawMethod) {
        orig_drawIndexedPrimitives = (void *)method_getImplementation(drawMethod);
        method_setImplementation(drawMethod, (IMP)hooked_drawIndexedPrimitives);
    }
}

// Точка входа в библиотеку (.dylib) — запускается автоматически при старте игры
__attribute__((constructor))
static void initializeChams() {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        swizzleMetalRenderEncoder();
        
        // Визуальное уведомление при входе в игру, чтобы ты знал, что чит подгрузился
        UIWindow *window = [[UIApplication sharedApplication] keyWindow];
        if (window && window.rootViewController) {
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Ollie Bench"
                                                                           message:@"Metal Chams активны. Скины рисуются сквозь стены."
                                                                    preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"Погнали" style:UIAlertActionStyleDefault handler:nil]];
            [window.rootViewController presentViewController:alert animated:YES completion:nil];
        }
    });
}
