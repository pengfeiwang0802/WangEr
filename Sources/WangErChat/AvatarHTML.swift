import Foundation

/// 虚拟形象的 HTML 模板 + JS 控制函数
/// 通过 WKWebView evaluateJavaScript 桥接控制表情/状态/SVG 内容
/// 
/// 表情控制原理：JS 直接修改 SVG 元素的属性（d、opacity 等），
/// 不依赖 CSS（因为 CSS 无法覆盖 SVG path 的 d 属性）
enum AvatarHTML {

    /// 完整的 HTML 页面，内嵌 SVG 和 JS 控制函数
    static let template: String = {
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>
          * { margin: 0; padding: 0; box-sizing: border-box; }
          body {
            background: transparent;
            display: flex;
            align-items: center;
            justify-content: center;
            height: 100vh;
            font-family: sans-serif;
          }
          svg { max-width: 100%; max-height: 100%; }

          /* 眨眼动画 — 压扁眼睛组（瞳孔 + 眼白一起压扁） */
          @keyframes blink {
            0%, 90% { transform: scaleY(1); }
            93% { transform: scaleY(0.1); }
            96% { transform: scaleY(1); }
          }

          .blinking .eye-left {
            animation: blink 4s infinite;
            transform-origin: 78px 105px;
          }
          .blinking .eye-right {
            animation: blink 4s infinite;
            transform-origin: 122px 105px;
          }
        </style>
        </head>
        <body>
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 260" width="100%" height="100%" id="avatarSvg">
          <!-- 背景 -->
          <rect width="200" height="260" rx="12" fill="#f0f4ff"/>
          <!-- 头发 -->
          <ellipse cx="100" cy="80" rx="70" ry="60" fill="#4a4a6a"/>
          <path d="M30 80 Q30 30 100 20 Q170 30 170 80" fill="#4a4a6a"/>
          <path d="M50 70 Q70 50 100 55 Q130 50 150 70" fill="none" stroke="#3a3a5a" stroke-width="2"/>
          <!-- 眉毛 -->
          <path id="brow-l" d="M65,90 Q78,85 90,90" fill="none" stroke="#4a4a6a" stroke-width="2.5" stroke-linecap="round"/>
          <path id="brow-r" d="M110,90 Q122,85 135,90" fill="none" stroke="#4a4a6a" stroke-width="2.5" stroke-linecap="round"/>
          <!-- 脸 -->
          <ellipse cx="100" cy="110" rx="55" ry="60" fill="#ffe4d6"/>
          <!-- 眼睛（眼白 + 瞳孔，用 group 包裹以支持眨眼缩放） -->
          <g id="eyes">
            <g class="eye-left">
              <ellipse cx="78" cy="105" rx="10" ry="12" fill="white"/>
              <ellipse cx="78" cy="105" rx="6" ry="8" fill="#3a3a5a"/>
              <ellipse cx="80" cy="103" rx="3" ry="3" fill="white"/>
            </g>
            <g class="eye-right">
              <ellipse cx="122" cy="105" rx="10" ry="12" fill="white"/>
              <ellipse cx="122" cy="105" rx="6" ry="8" fill="#3a3a5a"/>
              <ellipse cx="124" cy="103" rx="3" ry="3" fill="white"/>
            </g>
          </g>
          <!-- 嘴巴 -->
          <path id="mouth" d="M85,135 Q100,150 115,135" fill="none" stroke="#e88" stroke-width="2.5" stroke-linecap="round"/>
          <!-- 腮红 -->
          <ellipse id="blush-l" cx="62" cy="120" rx="10" ry="6" fill="#ffb3b3" opacity="0.4"/>
          <ellipse id="blush-r" cx="138" cy="120" rx="10" ry="6" fill="#ffb3b3" opacity="0.4"/>
          <!-- 身体 -->
          <path d="M55 165 Q55 230 60 250 L140 250 Q145 230 145 165" fill="#e8f0ff" stroke="#c0d0f0" stroke-width="1.5"/>
          <path d="M85 165 L100 185 L115 165" fill="none" stroke="#c0d0f0" stroke-width="2"/>
          <!-- 状态标签 -->
          <rect id="statusBadge" x="50" y="200" width="100" height="26" rx="13" fill="#6b9fff"/>
          <text id="statusText" x="100" y="217" text-anchor="middle" fill="white" font-size="12" font-family="sans-serif">😊 就绪</text>
        </svg>

        <script>
        // ========== 表情定义 ==========
        var EXPRESSIONS = {
          neutral: {
            'brow-l':  'M65,90 Q78,85 90,90',
            'brow-r':  'M110,90 Q122,85 135,90',
            'mouth':   'M85,138 L115,138',
            'blush-opacity': '0.2',
            'blinking': true
          },
          happy: {
            'brow-l':  'M65,88 Q78,82 90,88',
            'brow-r':  'M110,88 Q122,82 135,88',
            'mouth':   'M82,132 Q100,155 118,132',
            'blush-opacity': '0.7',
            'blinking': true
          },
          thinking: {
            'brow-l':  'M65,88 Q78,82 90,88',
            'brow-r':  'M110,88 Q122,78 135,85',
            'mouth':   'M88,138 Q100,142 112,138',
            'blush-opacity': '0.4',
            'blinking': false
          },
          sad: {
            'brow-l':  'M65,92 Q78,95 90,92',
            'brow-r':  'M110,92 Q122,95 135,92',
            'mouth':   'M88,140 Q100,130 112,140',
            'blush-opacity': '0.2',
            'blinking': true
          },
          surprised: {
            'brow-l':  'M65,85 Q78,78 90,85',
            'brow-r':  'M110,85 Q122,78 135,85',
            'mouth':   'M92,132 Q100,145 108,132',
            'blush-opacity': '0.4',
            'blinking': false
          }
        };

        // ========== JS 控制接口 ==========

        /** 设置表情：neutral / happy / thinking / sad / surprised */
        function setExpression(expr) {
          var valid = ['neutral', 'happy', 'thinking', 'sad', 'surprised'];
          if (valid.indexOf(expr) === -1) expr = 'neutral';
          var e = EXPRESSIONS[expr];
          if (!e) { console.log('[Avatar] EXPRESSIONS['+expr+'] is null'); return; }

          var svg = document.getElementById('avatarSvg');
          if (!svg) { console.log('[Avatar] svg not found'); return; }

          // 眉毛
          var bl = document.getElementById('brow-l');
          var br = document.getElementById('brow-r');
          if (!bl) console.log('[Avatar] brow-l not found');
          if (!br) console.log('[Avatar] brow-r not found');
          if (bl) bl.setAttribute('d', e['brow-l']);
          if (br) br.setAttribute('d', e['brow-r']);

          // 嘴巴
          var mouth = document.getElementById('mouth');
          if (!mouth) { console.log('[Avatar] mouth not found'); } else {
            mouth.setAttribute('d', e['mouth']);
            console.log('[Avatar] mouth set to: ' + e['mouth']);
          }

          // 腮红透明度
          var blushL = document.getElementById('blush-l');
          var blushR = document.getElementById('blush-r');
          if (blushL) blushL.setAttribute('opacity', e['blush-opacity']);
          if (blushR) blushR.setAttribute('opacity', e['blush-opacity']);

          // 眨眼控制
          if (e['blinking']) {
            svg.classList.add('blinking');
          } else {
            svg.classList.remove('blinking');
          }
          console.log('[Avatar] setExpression("'+expr+'") done');
        }

        /** 设置状态文本（底部标签） */
        function setStatus(text) {
          var el = document.getElementById('statusText');
          if (el) el.textContent = text;
        }

        /** 替换整个 SVG 内容（用于 AI 生成或模板切换） */
        function loadSVG(svgContent) {
          var container = document.querySelector('body');
          var oldSvg = document.getElementById('avatarSvg');
          if (oldSvg) oldSvg.remove();

          var parser = new DOMParser();
          var doc = parser.parseFromString(svgContent, 'image/svg+xml');
          var newSvg = doc.querySelector('svg');
          if (newSvg) {
            newSvg.id = 'avatarSvg';
            var script = document.querySelector('script');
            container.insertBefore(newSvg, script);
          }
        }

        /** 设置头发颜色 */
        function setHairColor(color) {
          var svg = document.getElementById('avatarSvg');
          if (!svg) return;
          var els = svg.querySelectorAll('[fill="#4a4a6a"]');
          els.forEach(function(el) { el.setAttribute('fill', color); });
          var brows = svg.querySelectorAll('[stroke="#4a4a6a"]');
          brows.forEach(function(el) { el.setAttribute('stroke', color); });
        }

        /** 设置背景颜色 */
        function setBgColor(color) {
          var svg = document.getElementById('avatarSvg');
          if (!svg) return;
          var rect = svg.querySelector('rect');
          if (rect) rect.setAttribute('fill', color);
        }

        /** 初始化：默认 neutral 表情 */
        setExpression('neutral');
        </script>
        </body>
        </html>
        """
    }()
}
