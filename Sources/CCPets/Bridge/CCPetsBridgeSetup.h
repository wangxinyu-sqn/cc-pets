#import <Foundation/Foundation.h>

// CC Bridge 的接入与移除：hooks、MCP 注册、Codex 工具审批与 Claude 工具放行（可选）。
//
// 与 Agent Hooks（CCPetsIntegrations.m）同一套约定：
//   - 按调用入口和参数匹配，每次只修复缺失或过期的条目；
//   - 配置文件先写临时文件再 rename，并保留原有的键顺序与格式；
//   - 没装的 CLI 不写（不凭空创建 ~/.claude、~/.codex）。
// Codex 注册和工具规则在同一次 TOML 编辑中合并、校验；Claude 原位更新 user scope 的注册。
// 配置文件解析失败时抛 NSException（reason 是给用户看的原因），由命令入口捕获。

extern NSString *const CCBridgeHookMarker;
extern NSString *const CCBridgeMCPName;

// 返回给用户看的报告行。registerMcp=NO 用于只改选项（桌宠开关、cc-pets bridge configure）。
NSArray<NSString *> *CCBridgeInstallForProfile(NSDictionary *profile, NSDictionary *options, BOOL registerMcp);
NSArray<NSString *> *CCBridgeUninstallForProfile(NSDictionary *profile, BOOL unregisterMcp, NSDictionary *oldOptions);
// CC_BRIDGE_SKIP_MCP=1 时不碰 claude / codex 的 MCP 注册（测试用）。
BOOL CCBridgeShouldTouchMCP(void);

// 自动唤醒 Codex 依赖 `codex queue`；不支持时返回一句说明，支持时返回 nil。
NSString *CCBridgeDescribeCodexQueue(NSDictionary *probe);
