//
//  R_SA.m
//  ResourceCryptor
//
//  Created by dqdeng on 2020/4/9.
//  Copyright © 2020 Jaden. All rights reserved.
//

#import "R_SA.h"
#import <CommonCrypto/CommonCrypto.h>
#import "ResourceCryptor.h"

// 填充模式
#define kTypeOfWrapPadding        kSecPaddingPKCS1

@interface NSData (RSA)
@property (nonatomic,readonly,assign)NSData *rsa_public_data; //
@property (nonatomic,readonly,assign)NSData *rsa_private_data; //
@end

static R_SA *shareInstance = nil;

@interface R_SA() {
    SecKeyRef _rsa_public_keyRef;                             // 公钥引用
    SecKeyRef _rsa_private_keyRef;                            // 私钥引用
}

@end

@implementation R_SA

+ (instancetype)share {
    if (shareInstance == nil) {
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            shareInstance = [[R_SA alloc] init];
        });
    }
    return shareInstance;
}

#pragma mark - RSA 加密/解密算法

- (R_SA_KEY_BLOCK)add_public_key_path {
    return ^(NSString *path) {
        [self rsa_public_key_path:path];
    };
}
- (R_SA_PRIVATEKEY_BLOCK)add_private_key_path {
    return ^(NSString *path,NSString *pwd) {
        [self rsa_private_key_path:path pwd:pwd];
    };
}

- (R_SA_KEY_BLOCK)add_public_key {
    return ^(NSString *key) {
        [self  rsa_public_key:key];
    };
}
- (R_SA_KEY_BLOCK)add_private_key {
    return ^(NSString *key) {
           [self  rsa_private_key:key];
       };
}

/// 加密str
- (RSA_EN_STR_BLOCK)EN_String {
    return ^(NSString *str){
        return [self RSA_EN_String:str];
    };
}
///解密data
- (RSA_EN_DATA_BLOCK)EN_Data {
    return ^(NSData *data){
        return [self RSA_EN_Data:data];
    };
}

/// 加密data
- (RSA_EN_DATA_BLOCK)DE_Data{
    return ^(NSData *data){
        return [self RSA_DE_Data:data];
    };
}

/// 解密str
- (RSA_EN_STR_BLOCK)DE_String {
    return ^(NSString *str) {
        return [self RSA_DE_String:str];
    };
}

@end


@implementation R_SA (Private)

- (NSString *)RSA_EN_String:(NSString *)string {
    return [self RSA_EN_Data:string.utf_8].base64_encoded_string;
}

- (NSString *)RSA_DE_String:(NSString *)string {
    return [self RSA_DE_Data:string.base_64_data].encoding_base64_UTF8StringEncoding;
}

- (NSData *)RSA_EN_Data:(NSData *)data {
    OSStatus sanityCheck = noErr;
    size_t cipherBufferSize = 0;
    size_t keyBufferSize = 0;
    
    NSAssert(data, @"data == nil");
    NSAssert(_rsa_public_keyRef, @"_rsa_public_keyRef == nil");
    
    NSData *cipher = nil;
    uint8_t *cipherBuffer = NULL;
    
    // 计算缓冲区大小
    cipherBufferSize = SecKeyGetBlockSize(_rsa_public_keyRef);
    keyBufferSize = data.length;
    
    if (kTypeOfWrapPadding == kSecPaddingNone) {
        NSAssert(keyBufferSize <= cipherBufferSize, @"EN too large");
    }
    
    // 分配缓冲区
    cipherBuffer = malloc(cipherBufferSize * sizeof(uint8_t));
    memset((void *)cipherBuffer, 0x0, cipherBufferSize);
    
    // 使用公钥加密
    sanityCheck = SecKeyEncrypt(_rsa_public_keyRef,
                                kTypeOfWrapPadding,
                                (const uint8_t *)data.bytes,
                                keyBufferSize,
                                cipherBuffer,
                                &cipherBufferSize
                                );
    
    NSAssert(sanityCheck == noErr, @"EN error，OSStatus == %d", sanityCheck);
    
    // 生成密文数据
    cipher = [NSData dataWithBytes:(const void *)cipherBuffer length:(NSUInteger)cipherBufferSize];
    
    if (cipherBuffer) free(cipherBuffer);
    
    return cipher;
}

- (NSData *)RSA_DE_Data:(NSData *)data {
    OSStatus sanityCheck = noErr;
    size_t cipherBufferSize = 0;
    size_t keyBufferSize = 0;
    
    NSData *key = nil;
    uint8_t *keyBuffer = NULL;
    
    SecKeyRef privateKey = _rsa_private_keyRef;
    NSAssert(privateKey != NULL, @"_rsa_private_keyRef == nil");
    
    // 计算缓冲区大小
    cipherBufferSize = SecKeyGetBlockSize(privateKey);
    keyBufferSize = data.length;
    
    NSAssert(keyBufferSize <= cipherBufferSize, @"DE  too large");
    
    // 分配缓冲区
    keyBuffer = malloc(keyBufferSize * sizeof(uint8_t));
    memset((void *)keyBuffer, 0x0, keyBufferSize);
    
    // 使用私钥解密
    sanityCheck = SecKeyDecrypt(privateKey,
                                kTypeOfWrapPadding,
                                (const uint8_t *)data.bytes,
                                cipherBufferSize,
                                keyBuffer,
                                &keyBufferSize
                                );
    
    NSAssert1(sanityCheck == noErr, @"DE error，OSStatus == %d", sanityCheck);
    
    // 生成明文数据
    key = [NSData dataWithBytes:(const void *)keyBuffer length:(NSUInteger)keyBufferSize];
    
    if (keyBuffer) free(keyBuffer);
    
    return key;
}

- (void)rsa_public_key_path:(NSString *)path; {
    
    NSAssert(path.length != 0, @"公钥路径为空");
    // 删除当前公钥
    if (_rsa_public_keyRef) CFRelease(_rsa_public_keyRef);
    
    // 从一个 DER 表示的证书创建一个证书对象
    NSData *certificateData = [NSData dataWithContentsOfFile:path];
    SecCertificateRef certificateRef = SecCertificateCreateWithData(kCFAllocatorDefault, (__bridge CFDataRef)certificateData);
    NSAssert(certificateRef != NULL, @"公钥文件错误");
    
    // 返回一个默认 X509 策略的公钥对象
    SecPolicyRef policyRef = SecPolicyCreateBasicX509();
    // 包含信任管理信息的结构体
    SecTrustRef trustRef;
    
    // 基于证书和策略创建一个信任管理对象
    OSStatus status = SecTrustCreateWithCertificates(certificateRef, policyRef, &trustRef);
    NSAssert(status == errSecSuccess, @"创建信任管理对象失败");
    
    // 信任结果
    // 评估指定证书和策略的信任管理是否有效
    //#if __IPHONE_OS_VERSION_MAX_ALLOWED > __IPHONE_10_3
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    if (@available(iOS 12, macOS 10.14, tvOS 12, watchOS 5, *)) {
        CFErrorRef error;
        if (SecTrustEvaluateWithError(trustRef,&error) == NO){}
    } else {
        SecTrustResultType trustResult;
        status = SecTrustEvaluate(trustRef, &trustResult);
    }
    // 评估之后返回公钥子证书
    _rsa_public_keyRef = SecTrustCopyPublicKey(trustRef);
    NSAssert(_rsa_public_keyRef != NULL, @"公钥创建失败");
    
    if (certificateRef) CFRelease(certificateRef);
    if (policyRef) CFRelease(policyRef);
    if (trustRef) CFRelease(trustRef);
}

- (void)rsa_public_key:(NSString *)key {
    
    NSRange spos = [key rangeOfString:@"-----BEGIN PUBLIC KEY-----"];
    NSRange epos = [key rangeOfString:@"-----END PUBLIC KEY-----"];
    if(spos.location != NSNotFound && epos.location != NSNotFound){
        NSUInteger s = spos.location + spos.length;
        NSUInteger e = epos.location;
        NSRange range = NSMakeRange(s, e-s);
        key = [key substringWithRange:range];
    }
    key = [key stringByReplacingOccurrencesOfString:@"\r" withString:@""];
    key = [key stringByReplacingOccurrencesOfString:@"\n" withString:@""];
    key = [key stringByReplacingOccurrencesOfString:@"\t" withString:@""];
    key = [key stringByReplacingOccurrencesOfString:@" "  withString:@""];
    
    // This will be base64 encoded, decode it.
    NSData *data = key.base_64_data;
    data = data.rsa_public_data;
    if(!data){
        return ;
    }
    
    //a tag to read/write keychain storage
    NSString *tag = @"RSAUtil_PubKey";
    NSData *d_tag = [NSData dataWithBytes:[tag UTF8String] length:[tag length]];
    
    // Delete any old lingering key with the same tag
    NSMutableDictionary *publicKey = [[NSMutableDictionary alloc] init];
    [publicKey setObject:(__bridge id) kSecClassKey forKey:(__bridge id)kSecClass];
    [publicKey setObject:(__bridge id) kSecAttrKeyTypeRSA forKey:(__bridge id)kSecAttrKeyType];
    [publicKey setObject:d_tag forKey:(__bridge id)kSecAttrApplicationTag];
    SecItemDelete((__bridge CFDictionaryRef)publicKey);
    
    // Add persistent version of the key to system keychain
    [publicKey setObject:data forKey:(__bridge id)kSecValueData];
    [publicKey setObject:(__bridge id) kSecAttrKeyClassPublic forKey:(__bridge id)
     kSecAttrKeyClass];
    [publicKey setObject:[NSNumber numberWithBool:YES] forKey:(__bridge id)
     kSecReturnPersistentRef];
    
    CFTypeRef persistKey = nil;
    OSStatus status = SecItemAdd((__bridge CFDictionaryRef)publicKey, &persistKey);
    if (persistKey != nil){
        CFRelease(persistKey);
    }
    if ((status != noErr) && (status != errSecDuplicateItem)) {
        return ;
    }
    
    [publicKey removeObjectForKey:(__bridge id)kSecValueData];
    [publicKey removeObjectForKey:(__bridge id)kSecReturnPersistentRef];
    [publicKey setObject:[NSNumber numberWithBool:YES] forKey:(__bridge id)kSecReturnRef];
    [publicKey setObject:(__bridge id) kSecAttrKeyTypeRSA forKey:(__bridge id)kSecAttrKeyType];
    
    // 删除当前公钥
    if (_rsa_public_keyRef) CFRelease(_rsa_public_keyRef);
    // Now fetch the SecKeyRef version of the key
    _rsa_public_keyRef = nil;
    status = SecItemCopyMatching((__bridge CFDictionaryRef)publicKey, (CFTypeRef *)&_rsa_public_keyRef);
}

- (void)rsa_private_key_path:(NSString *)path pwd:(NSString *)pwd {
    
    NSAssert(path.length != 0, @"私钥路径为空");
    // 删除当前私钥
    if (_rsa_private_keyRef) CFRelease(_rsa_private_keyRef);
    
    NSData *PKCS12Data = [NSData dataWithContentsOfFile:path];
    CFDataRef inPKCS12Data = (__bridge CFDataRef)PKCS12Data;
    CFStringRef passwordRef = (__bridge CFStringRef)pwd;
    
    // 从 PKCS #12 证书中提取标示和证书
    SecIdentityRef myIdentity;
    SecTrustRef myTrust;
    const void *keys[] = {kSecImportExportPassphrase};
    const void *values[] = {passwordRef};
    CFDictionaryRef optionsDictionary = CFDictionaryCreate(NULL, keys, values, 1, NULL, NULL);
    CFArrayRef items = CFArrayCreate(NULL, 0, 0, NULL);
    
    // 返回 PKCS #12 格式数据中的标示和证书
    OSStatus status = SecPKCS12Import(inPKCS12Data, optionsDictionary, &items);
    CFDictionaryRef myIdentityAndTrust = CFArrayGetValueAtIndex(items, 0);
    myIdentity = (SecIdentityRef)CFDictionaryGetValue(myIdentityAndTrust, kSecImportItemIdentity);
    myTrust = (SecTrustRef)CFDictionaryGetValue(myIdentityAndTrust, kSecImportItemTrust);
    
    if (optionsDictionary) CFRelease(optionsDictionary);
    NSAssert(status == noErr, @"提取身份和信任失败");
    
    // 评估指定证书和策略的信任管理是否有效
    if (@available(iOS 12, macOS 10.14, tvOS 12, watchOS 5, *)) {
        CFErrorRef error;
        if (SecTrustEvaluateWithError(myTrust,&error) == NO){}
    } else {
        SecTrustResultType trustResult;
        status = SecTrustEvaluate(myTrust, &trustResult);
    }
    
    // 提取私钥
    status = SecIdentityCopyPrivateKey(myIdentity, &_rsa_private_keyRef);
    NSAssert(status == errSecSuccess, @"私钥创建失败");
    CFRelease(items);
}

- (void)rsa_private_key:(NSString *)key {
    NSRange spos;
    NSRange epos;
    spos = [key rangeOfString:@"-----BEGIN RSA PRIVATE KEY-----"];
    if(spos.length > 0){
        epos = [key rangeOfString:@"-----END RSA PRIVATE KEY-----"];
    }else{
        spos = [key rangeOfString:@"-----BEGIN PRIVATE KEY-----"];
        epos = [key rangeOfString:@"-----END PRIVATE KEY-----"];
    }
    if(spos.location != NSNotFound && epos.location != NSNotFound){
        NSUInteger s = spos.location + spos.length;
        NSUInteger e = epos.location;
        NSRange range = NSMakeRange(s, e-s);
        key = [key substringWithRange:range];
    }
    key = [key stringByReplacingOccurrencesOfString:@"\r" withString:@""];
    key = [key stringByReplacingOccurrencesOfString:@"\n" withString:@""];
    key = [key stringByReplacingOccurrencesOfString:@"\t" withString:@""];
    key = [key stringByReplacingOccurrencesOfString:@" "  withString:@""];
    
    // This will be base64 encoded, decode it.
    NSData *data = key.base_64_data;
    data = data.rsa_private_data;
    if(!data){
        return;
    }
    
    //a tag to read/write keychain storage
    NSString *tag = @"RSAUtil_PrivKey";
    NSData *d_tag = [NSData dataWithBytes:[tag UTF8String] length:[tag length]];
    
    // Delete any old lingering key with the same tag
    NSMutableDictionary *privateKey = [[NSMutableDictionary alloc] init];
    [privateKey setObject:(__bridge id) kSecClassKey forKey:(__bridge id)kSecClass];
    [privateKey setObject:(__bridge id) kSecAttrKeyTypeRSA forKey:(__bridge id)kSecAttrKeyType];
    [privateKey setObject:d_tag forKey:(__bridge id)kSecAttrApplicationTag];
    SecItemDelete((__bridge CFDictionaryRef)privateKey);
    
    // Add persistent version of the key to system keychain
    [privateKey setObject:data forKey:(__bridge id)kSecValueData];
    [privateKey setObject:(__bridge id) kSecAttrKeyClassPrivate forKey:(__bridge id)
     kSecAttrKeyClass];
    [privateKey setObject:[NSNumber numberWithBool:YES] forKey:(__bridge id)
     kSecReturnPersistentRef];
    
    CFTypeRef persistKey = nil;
    OSStatus status = SecItemAdd((__bridge CFDictionaryRef)privateKey, &persistKey);
    if (persistKey != nil){
        CFRelease(persistKey);
    }
    if ((status != noErr) && (status != errSecDuplicateItem)) {
        return ;
    }
    
    [privateKey removeObjectForKey:(__bridge id)kSecValueData];
    [privateKey removeObjectForKey:(__bridge id)kSecReturnPersistentRef];
    [privateKey setObject:[NSNumber numberWithBool:YES] forKey:(__bridge id)kSecReturnRef];
    [privateKey setObject:(__bridge id) kSecAttrKeyTypeRSA forKey:(__bridge id)kSecAttrKeyType];
    
    // 删除当前私钥
    if (_rsa_private_keyRef) CFRelease(_rsa_private_keyRef);
    // Now fetch the SecKeyRef version of the key
    _rsa_private_keyRef = nil;
    status = SecItemCopyMatching((__bridge CFDictionaryRef)privateKey, (CFTypeRef *)&_rsa_private_keyRef);
    if(status != noErr){
        return ;
    }
    
}

@end