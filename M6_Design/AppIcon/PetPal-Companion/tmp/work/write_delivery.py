import json
from pathlib import Path
r=Path('/Users/benyanzhou/Documents/Codex/app/PetPal/M6_Design/AppIcon/PetPal-Companion')
concept='以并肩依偎的猫狗作为社区入口，将真实宠物的垂耳、尖耳与放松神态转化为简洁轮廓。奶油白承载柔软陪伴，暖橙传递日常温度；上方的爱心对话气泡把喜欢宠物自然连接到同好交流。面向都市成年养宠人群，以克制的表情、留白和双色关系营造治愈感与信任感，避免玩具式装饰和商务徽章感。'
text='''# PetPal 猫狗陪伴 App Icon 设计规范

## （1）禁止项自查清单

- 文字、英文字母、阿拉伯数字：通过。图像内无可见文字，无 SVG text 元素；代码中的 id 和坐标不渲染为文字。
- 复杂背景纹理：通过。背景纯色，无噪点、大理石、毛发纹理。
- 3D 渲染：通过。无投影、透视、浮雕或镜面效果；仅狗耳内使用微弱线性渐变。
- 超过三种主色：通过。仅暖橙、奶油白两种色系；#F5D2AF 为橙色渐变端点。
- 补充检查：无照片、暗黑主图、服饰、工具或直立动物。

## （2）设计理念

'''+concept+'''

## （3）视觉元素拆解

- 狗狗位于左前方，保留垂耳、圆润吻部与鼻头。两只眼睛中心有 10px 高度差，表现轻微歪头；18px 直径眼睛高光辅助亲和表情。
- 猫咪位于右后方，保留尖耳、三角鼻、分叉口鼻线及右侧胡须；闭眼弧线表达放松。
- 爱心对话气泡位于上方；既表达交流，也表达关怀。气泡与猫耳之间留出约 26px 垂直间隙。
- 核心图形实测边界：x=165–846px，y=121–827px，约占画布宽 66.6%、高 69.0%；计算使用前景 alpha >10/255 的边界。
- 主线条为 18/20/22/24px；60px 下相当于 1.05/1.17/1.29/1.41px。图形辨识依赖猫狗耳形、鼻口与气泡轮廓；高光属于辅助细节。

## （4）iOS 与 Android 规范适配说明

- iOS：1024×1024px 方形不透明主图，由系统施加圆角。交付的圆角预览使用 r=229.0688px（22.37%），这是按需求采用的近似预览，不是 Apple 固定圆弧半径规范。
- 本案安全区为 x/y=102.4–921.6px，即每边留 102.4px、中心 819.2px；这是设计约束，不声称为 Apple 官方统一值。实际核心元素距画布四边至少 121px。
- Android：前景、背景分层，设计坐标 108×108dp，核心控制在中心 66×66dp 安全区，按中心直径 66dp 圆形进行保守检查。安全区外接框距各边 21dp，对应 1024 画布每边 199.11px；另有外侧 18dp 动效空间概念，两者不要混用。
- Android 微调：背景铺满，动物和社交符号同时围绕 (512,512) 缩放至 75%，SVG 变换为 translate(512 512) scale(.75) translate(-512 -512)。最大前景半径由 406.89px 缩至 305.16px，小于安全半径 312.89px。采用系统圆形、方圆形等遮罩，不预先烘焙 iOS 圆角。细节线宽若调整，应重新检查边界。
- 当前交付为通用 SVG/PNG 源资产，平台元数据为 iOS、Android；iOS 为主要视觉目标。没有生成 .icon、Android 原生资源包或验证真机渲染。
- 官方依据（查阅日期 2026-10-04）：[Apple App Icons](https://developer.apple.com/design/human-interface-guidelines/app-icons)、[Android Adaptive Icons](https://developer.android.com/develop/ui/compose/system/icon_design_adaptive)。

## （5）配色方案

| 用途 | 色号 | 最终方形 PNG 可见面积 |
|---|---|---:|
| 主色：背景、五官、爱心、狗脸分隔线 | #E9AC7D | 77.55% |
| 辅助色：猫狗面部、气泡、眼睛高光及耳部描边 | #FFF4E6 | 20.08% |
| 狗耳渐变及全图抗锯齿过渡像素 | #F5D2AF → #E9AC7D | 2.37% |

面积来自 1024px 主图逐像素统计；最后一行包含全部抗锯齿混合像素，不等于纯渐变面积。背景层几何上覆盖 100% 画布，上表为叠加后的可见面积。

明度采用 HSL L：暖橙 70.20%，奶油白 95.10%，渐变浅端 82.35%；全图平均 75.38%，最小 70.20%。耳部渐变明度差 12.16 个百分点，相对较深端约 17.32%。它只作用于双耳，不作用于背景和脸部。

## （6）最终交付物

- 主图：petpal-companion.svg、petpal-companion.png，1024×1024，不透明、无圆角裁切。
- 预览：petpal-companion.preview.svg、petpal-companion.preview.png，1024×1024，外部透明、22.37% 圆角近似遮罩。
- 图层：layers/01-background.svg、layers/02-animals.svg、layers/03-social-symbol.svg。
- 60px、64px、白底和黑底预览位于 tmp/work；校验报告位于 tmp/reports。
- 本图为根据文字简报直接绘制的新概念，无沿用的参考素材，因此无 origin 参考文件。

### 分层规范（从下到上）

| 顺序 | 语义 id | 颜色 | 尺寸与位置 | 叠加关系 |
|---|---|---|---|---|
| 1 | background-layer | #E9AC7D | 1024×1024，100% 画布 | 最底层实底 |
| 2a | animals-layer / cat | 面部 #FFF4E6，五官 #E9AC7D | 轮廓约 354×408px，占 34.6%×39.9%；x≈493–847，y≈338–746 | 猫在狗后方；依次轮廓、内耳、眼、鼻、嘴、胡须 |
| 2b | animals-layer / dog | 面部 #FFF4E6，五官/分隔线 #E9AC7D；耳 #F5D2AF→#E9AC7D | 含描边约 435×425px，占 42.5%×41.5%；左前方；眼睛 48×58px | 依次右耳、头部、左耳、眼睛、高光、鼻、嘴；头部橙色 24px 描边隔开两张脸 |
| 3 | social-symbol-layer | 气泡 #FFF4E6，心形 #E9AC7D | 气泡宽 285px（27.8%），含尾高约 191px（18.7%）；x=368–653，y≈121–312 | 最上层；先气泡后爱心；整体 translate(0,-56) |

所有图层完全不透明；只有预览在方形之外使用透明角区。耳部线性渐变方向为自上而下，作用于每只耳朵自身的包围盒。

### 白底与黑底预览

- #FFFFFF：暖橙外轮廓与白底对比度约 1.97:1；观感轻柔，边界清楚但并非强对比。
- #000000：暖橙与黑底约 10.66:1，外轮廓明显突出，视觉上显得更亮、更暖。素材 RGB 值相同，无由背景引起的实际颜色变更；描述的明暗变化为同时对比感知。
- 两种底色下，奶油白与暖橙的内部对比度均约 1.81:1。60px/64px 实际预览中，猫狗轮廓、面部表情和心形气泡可辨；这是本次视觉检查结论，不是可访问性文字对比度认证。
- 预览外部的黑白是展示环境色，不进入图标主色统计。以上适用于交付的原色图标，不代表系统深色或着色模式渲染。

### 可直接运行的完整 SVG

```svg
'''+(r/'petpal-companion.svg').read_text()+'''```

禁止项自查通过。
'''
(r/'tmp/设计规范.md').write_text(text)
review={'decision':'accepted','reviewer':'main-agent original-concept visual inspection','evidence':['petpal-companion.svg','petpal-companion.png','petpal-companion.preview.png','tmp/work/preview-60.png','tmp/work/preview-64.png','tmp/work/light-dark-board.png','tmp/reports/design-audit.json','tmp/reports/geometry-animals.json'],'notes':'Original low-identity-risk concept directly authored from user brief. Full-size source and rounded preview plus 60/64px samples and light/dark surrounds reviewed. Cat and dog remain distinguishable, chat bubble and heart readable. Ear/eye occlusion repaired and bubble separated from cat ear. Geometry info flags correspond to intentional paired eyes, ears, mouth branches, whiskers, and overlap of distinct animals, not accidental holes. All source strokes >=18px. Foreground within central 80%. Two color families; no text, texture, photo, clothes, props, 3D or shadow. Flat pale palette intentionally has moderate internal contrast. Source package only; no platform-render claim.'}
(r/'tmp/reports/visual-review.json').write_text(json.dumps(review,indent=2))
print('Concept length:',len(concept))
