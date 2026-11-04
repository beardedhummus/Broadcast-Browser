//
//  SyphonBuiltIn.h
//  Broadcast Browser compiles Syphon (BSD, see License.txt) directly into the
//  app. Calling this from the bridge makes sure the linker keeps the classes,
//  which are otherwise only looked up by name at runtime.
//

#ifndef SyphonBuiltIn_h
#define SyphonBuiltIn_h

#ifdef __cplusplus
extern "C" {
#endif

void SyphonBuiltInLink(void);

#ifdef __cplusplus
}
#endif

#endif /* SyphonBuiltIn_h */
