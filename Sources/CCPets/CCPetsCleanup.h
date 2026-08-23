#import <Foundation/Foundation.h>

// 启动时只清理已经过期且不再有展示价值的临时状态。
void PruneStaleRuntimeState(void);

// clean 删除可重建缓存；purge 额外删除历史、更新配置和用户偏好。
int CleanCCPetsData(BOOL purge);
