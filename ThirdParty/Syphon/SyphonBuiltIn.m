//
//  SyphonBuiltIn.m
//

#import "SyphonBuiltIn.h"
#import "SyphonMetalServer.h"
#import "SyphonServerDirectory.h"

void SyphonBuiltInLink(void) {
    (void)[SyphonMetalServer class];
    (void)[SyphonServerDirectory class];
}
