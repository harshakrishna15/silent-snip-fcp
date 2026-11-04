#import <Foundation/Foundation.h>

// Controller harness only. The production build uses swiftc's generated
// header and the real Swift bridge. This declaration is supplied through the
// test include path so loading a controller cannot open a settings file.
NS_ASSUME_NONNULL_BEGIN
@interface SSWorkflowSettingsBridge : NSObject
- (void)loadForLibraryURL:(NSURL *)libraryURL
              projectUID:(NSString *)projectUID
              completion:(void (^)(NSDictionary * _Nullable, NSError * _Nullable))completion;
- (void)saveValues:(NSDictionary *)values
       libraryURL:(NSURL *)libraryURL
       projectUID:(NSString *)projectUID
       completion:(void (^)(NSError * _Nullable))completion;
@end
NS_ASSUME_NONNULL_END
