import { motion } from 'motion/react';
import { 
  ShieldCheck, 
  Brain, 
  Target, 
  BookOpen, 
  MessageCircleQuestion, 
  Sun, 
  CheckCircle2, 
  Sparkles,
  HeartHandshake
} from 'lucide-react';

const FADE_UP_ANIMATION_VARIANTS = {
  hidden: { opacity: 0, y: 30 },
  show: { opacity: 1, y: 0, transition: { type: 'spring', stiffness: 100, damping: 15 } }
};

const STAGGER_CONTAINER = {
  hidden: { opacity: 0 },
  show: {
    opacity: 1,
    transition: { staggerChildren: 0.15 }
  }
};

export default function App() {
  return (
    <div className="min-h-screen bg-stone-50 text-stone-800 font-sans selection:bg-teal-100 selection:text-teal-900 pb-20">
      {/* Header Section */}
      <header className="bg-white pt-20 pb-12 px-6 border-b border-stone-100 shadow-sm">
        <motion.div 
          initial="hidden"
          animate="show"
          variants={STAGGER_CONTAINER}
          className="max-w-4xl mx-auto text-center"
        >
          <motion.div variants={FADE_UP_ANIMATION_VARIANTS} className="inline-block mb-4 px-4 py-1.5 bg-teal-50 text-teal-700 border border-teal-100/50 text-sm font-medium rounded-full tracking-widest uppercase">
            学期末总结展望
          </motion.div>
          <motion.h1 variants={FADE_UP_ANIMATION_VARIANTS} className="text-4xl md:text-5xl font-bold tracking-tight text-stone-900 mb-4">
            小家伙家长会总结
          </motion.h1>
          <motion.p variants={FADE_UP_ANIMATION_VARIANTS} className="text-lg text-stone-500 max-w-2xl mx-auto">
            英语班主任分享要点 · 暑期生活指引 · 家校合作规划
          </motion.p>
        </motion.div>
      </header>

      <main className="max-w-4xl mx-auto px-6 space-y-16 mt-12">
        
        {/* Core Philosophy */}
        <motion.section 
          initial="hidden"
          animate="show"
          variants={STAGGER_CONTAINER}
        >
          <motion.h2 variants={FADE_UP_ANIMATION_VARIANTS} className="text-2xl font-bold text-stone-900 mb-6 flex items-center gap-2">
            <HeartHandshake className="text-teal-600" /> 核心理念
          </motion.h2>
          <div className="grid grid-cols-1 md:grid-cols-3 gap-6">
            <motion.div variants={FADE_UP_ANIMATION_VARIANTS} className="bg-white p-6 rounded-2xl border border-stone-100 shadow-sm hover:shadow-md hover:border-teal-100 transition-all">
              <ShieldCheck className="w-8 h-8 text-teal-500 mb-4" />
              <h3 className="font-semibold text-lg text-stone-900 mb-2">安全第一</h3>
              <p className="text-stone-500 text-sm leading-relaxed">
                健康与安全大于一切。这是所有学习与成长的根本前提。
              </p>
            </motion.div>
            <motion.div variants={FADE_UP_ANIMATION_VARIANTS} className="bg-white p-6 rounded-2xl border border-stone-100 shadow-sm hover:shadow-md hover:border-teal-100 transition-all">
              <Brain className="w-8 h-8 text-teal-500 mb-4" />
              <h3 className="font-semibold text-lg text-stone-900 mb-2">内核稳定</h3>
              <p className="text-stone-500 text-sm leading-relaxed">
                培养孩子稳定的情绪和心理状态，以平静从容的心态面对学习挑战。
              </p>
            </motion.div>
            <motion.div variants={FADE_UP_ANIMATION_VARIANTS} className="bg-white p-6 rounded-2xl border border-stone-100 shadow-sm hover:shadow-md hover:border-teal-100 transition-all">
              <Target className="w-8 h-8 text-teal-500 mb-4" />
              <h3 className="font-semibold text-lg text-stone-900 mb-2">多元评价</h3>
              <p className="text-stone-500 text-sm leading-relaxed">
                多元化看待孩子的进步，不仅仅依靠分数来衡量成长与优秀。
              </p>
            </motion.div>
          </div>
        </motion.section>

        {/* Academic Strategy */}
        <motion.section 
          initial="hidden"
          animate="show"
          variants={STAGGER_CONTAINER}
          className="bg-white rounded-3xl p-8 border border-stone-100 shadow-sm"
        >
          <motion.h2 variants={FADE_UP_ANIMATION_VARIANTS} className="text-2xl font-bold text-stone-900 mb-6 flex items-center gap-2">
            <BookOpen className="text-teal-600" /> 期末备考与学习策略
          </motion.h2>
          <div className="space-y-4">
            <motion.div variants={FADE_UP_ANIMATION_VARIANTS} className="p-5 bg-teal-50/50 rounded-xl border border-teal-100/50 flex items-start gap-4">
              <div className="p-2 bg-teal-100 text-teal-700 rounded-lg shrink-0">
                <Target size={20} />
              </div>
              <div>
                <h4 className="font-semibold text-teal-900 mb-1">主基调：复习 大于 遇新</h4>
                <p className="text-teal-700/80 text-sm">温故而知新，现阶段重点在于巩固已有知识，而非一味追求新进展。</p>
              </div>
            </motion.div>
            
            <motion.div variants={FADE_UP_ANIMATION_VARIANTS} className="grid grid-cols-1 sm:grid-cols-2 gap-4 mt-4">
              <div className="flex items-center gap-3 text-stone-600 bg-stone-50 p-3 rounded-lg border border-stone-100">
                <CheckCircle2 className="text-teal-500 w-5 h-5 shrink-0" />
                <span className="text-sm">夯实基础知识扎实度</span>
              </div>
              <div className="flex items-center gap-3 text-stone-600 bg-stone-50 p-3 rounded-lg border border-stone-100">
                <CheckCircle2 className="text-teal-500 w-5 h-5 shrink-0" />
                <span className="text-sm">提升上课专注度</span>
              </div>
              <div className="flex items-center gap-3 text-stone-600 bg-stone-50 p-3 rounded-lg border border-stone-100">
                <CheckCircle2 className="text-teal-500 w-5 h-5 shrink-0" />
                <span className="text-sm">确保作业完成质量</span>
              </div>
              <div className="flex items-center gap-3 text-stone-600 bg-stone-50 p-3 rounded-lg border border-stone-100">
                <CheckCircle2 className="text-teal-500 w-5 h-5 shrink-0" />
                <span className="text-sm">提高考试后复盘效率，发挥试卷价值</span>
              </div>
            </motion.div>
          </div>
        </motion.section>

        {/* Q&A section with personal insights */}
        <motion.section 
          initial="hidden"
          animate="show"
          variants={STAGGER_CONTAINER}
        >
          <motion.h2 variants={FADE_UP_ANIMATION_VARIANTS} className="text-2xl font-bold text-stone-900 mb-6 flex items-center gap-2">
            <MessageCircleQuestion className="text-teal-600" /> 家长提问与深度反思
          </motion.h2>

          <div className="space-y-8">
            {/* Q1 */}
            <motion.div variants={FADE_UP_ANIMATION_VARIANTS} className="bg-white rounded-2xl overflow-hidden border border-stone-100 shadow-sm">
              <div className="p-6">
                <div className="mb-4">
                  <span className="inline-block px-3 py-1 bg-stone-100 text-stone-600 text-xs font-semibold rounded-full mb-4 tracking-wider uppercase">
                    讨论一
                  </span>
                  <h3 className="font-semibold text-lg text-stone-900 mb-2 leading-snug">
                    孩子长期过度松弛，对待成绩“不以物喜，不以己悲”，缺乏成就感怎么办？
                  </h3>
                  <div className="p-4 bg-stone-50 rounded-xl text-stone-600 text-sm mt-4 border-l-2 border-teal-500">
                    <span className="font-semibold text-stone-800">老师回复：</span>
                    这样的心态其实“利大于弊”。但如果缺乏成就感，确实会削弱自驱力。真正的松弛感应该建立在“成就感”的基础之上，成就感是主干，缺乏了主干则会产生问题。
                  </div>
                </div>

                {/* Personal Insight */}
                <div className="mt-6 bg-teal-50/50 rounded-xl p-5 border border-teal-100/50">
                  <h4 className="flex items-center gap-2 font-semibold text-teal-700 mb-3 text-sm">
                    <Sparkles className="w-4 h-4 text-teal-600" /> 家长总结与反思
                  </h4>
                  <p className="text-teal-900/80 text-sm leading-relaxed">
                    老师提到的“以成就感为主干”非常关键。过度松弛可能是一种自我保护机制。我们不仅要接纳、欣赏孩子这份难得的心态定力，更要在日常中刻意为她创造<strong className="font-semibold text-teal-700 mx-1">“微小的成就感”</strong>。
                    不要只用大考成绩衡量，而应把大目标拆解成小任务。及时给予具体且正向的反馈，以此自然唤醒内在驱动力，让目前的“松弛”升华为自信的“从容”。
                  </p>
                </div>
              </div>
            </motion.div>

            {/* Q2 */}
            <motion.div variants={FADE_UP_ANIMATION_VARIANTS} className="bg-white rounded-2xl overflow-hidden border border-stone-100 shadow-sm">
              <div className="p-6">
                <div className="mb-4">
                  <span className="inline-block px-3 py-1 bg-stone-100 text-stone-600 text-xs font-semibold rounded-full mb-4 tracking-wider uppercase">
                    讨论二
                  </span>
                  <h3 className="font-semibold text-lg text-stone-900 mb-2 leading-snug">
                    背单词太枯燥，除了老师布置的任务以外，孩子毫无主动拓展的意愿怎么办？
                  </h3>
                  <div className="p-4 bg-stone-50 rounded-xl text-stone-600 text-sm mt-4 border-l-2 border-teal-500">
                    <span className="font-semibold text-stone-800">老师回复：</span>
                    不需要锁定在某一单一任务（如死记硬背）上来提升能力。应当通过多元化、兴趣化的方式，全面提升整体的听、读、理解能力。
                  </div>
                </div>

                {/* Personal Insight */}
                <div className="mt-6 bg-teal-50/50 rounded-xl p-5 border border-teal-100/50">
                  <h4 className="flex items-center gap-2 font-semibold text-teal-700 mb-3 text-sm">
                    <Sparkles className="w-4 h-4 text-teal-600" /> 家长总结与反思
                  </h4>
                  <p className="text-teal-900/80 text-sm leading-relaxed">
                    语言学习的本质是“交流的使用工具”，而非“枯燥的通关任务”。死记硬背极易消耗孩子的热情。接下来的暑假不妨调整策略，把英语融入她感兴趣的事物中。
                    <strong className="font-semibold text-teal-700 mx-1">通过“浸入”代替“强制”</strong>，在兴趣横生中自然习得。当她发现自己能毫无障碍地听懂喜欢的原文故事时，内驱力和词汇量自会水到渠成地增长。
                  </p>
                </div>
              </div>
            </motion.div>

            {/* Q3 */}
            <motion.div variants={FADE_UP_ANIMATION_VARIANTS} className="bg-white rounded-2xl overflow-hidden border border-stone-100 shadow-sm">
              <div className="p-6">
                <div className="mb-4">
                  <div className="flex flex-wrap items-center gap-2 mb-3">
                    <span className="inline-block px-3 py-1 bg-stone-100 text-stone-600 text-xs font-semibold rounded-full tracking-wider uppercase">
                      讨论三
                    </span>
                    <span className="inline-flex items-center gap-1.5 px-3 py-1 bg-orange-50 text-orange-700 border border-orange-100 text-xs font-semibold rounded-full tracking-wider">
                      深度交流
                    </span>
                    <span className="text-xs text-stone-500 ml-1">
                      (会后我单独向老师请教的问题)
                    </span>
                  </div>
                  <h3 className="font-semibold text-lg text-stone-900 mb-2 leading-snug">
                    用小程序游戏的方式巩固练习，单一板块突破明显，但全卷总分并未见明显提升，这种游戏化学习帮助大吗？
                  </h3>
                  <div className="p-4 bg-stone-50 rounded-xl text-stone-600 text-sm mt-4 border-l-2 border-teal-500">
                    <span className="font-semibold text-stone-800">老师回复：</span>
                    通过游戏去巩固是非常明智且有效的方法。未在全卷显现出突破的主因是<strong className="text-stone-800 font-medium">“年龄”</strong>的限制。随着年龄的积累，专注力会慢慢提升，孩子也会逐渐培养出应对全卷的习惯和自己的解题策略。我们需要接受并理性看待现阶段的生理年龄限制。
                  </div>
                </div>

                {/* Personal Insight */}
                <div className="mt-6 bg-teal-50/50 rounded-xl p-5 border border-teal-100/50">
                  <h4 className="flex items-center gap-2 font-semibold text-teal-700 mb-3 text-sm">
                    <Sparkles className="w-4 h-4 text-teal-600" /> 家长总结与反思
                  </h4>
                  <p className="text-teal-900/80 text-sm leading-relaxed">
                    学习是一项长期工程，能力的拔节也绝非一蹴而就。单项技能的提升好比积攒一块块拼图，而将它们拼成“应对全卷”的综合能力，则必须以<strong className="font-semibold text-teal-700 mx-1">时间与心智发育成熟度</strong>作为粘合剂。
                    继续保持轻松有趣的强化方式吧，做时间的朋友，静待她的专注力与全局掌控力随年龄自然爆发。
                  </p>
                </div>
              </div>
            </motion.div>
          </div>
        </motion.section>

        {/* Summer Plans & Habits */}
        <motion.section 
          initial="hidden"
          animate="show"
          variants={STAGGER_CONTAINER}
        >
          <motion.h2 variants={FADE_UP_ANIMATION_VARIANTS} className="text-2xl font-bold text-stone-900 mb-6 flex items-center gap-2">
            <Sun className="text-teal-600" /> 暑期规划与习惯养成
          </motion.h2>

          <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
             <motion.div variants={FADE_UP_ANIMATION_VARIANTS} className="bg-white p-5 rounded-xl border border-stone-100 shadow-sm">
              <h4 className="font-semibold text-stone-900 mb-2">
                多元阅读 弯道超车
              </h4>
              <p className="text-sm text-stone-500">看 "Such Little Fox" 等视频，读英文绘本，在放松中重点练习语言的反应和理解能力。</p>
            </motion.div>

            <motion.div variants={FADE_UP_ANIMATION_VARIANTS} className="bg-white p-5 rounded-xl border border-stone-100 shadow-sm relative overflow-hidden">
              <div className="absolute -right-6 -top-6 text-teal-50 opacity-50">
                <CheckCircle2 size={80} />
              </div>
              <h4 className="font-semibold text-stone-900 flex items-center gap-2 mb-2 relative z-10">
                作息管理
                <span className="px-2 py-0.5 bg-teal-50 text-teal-700 text-xs rounded-full">表现优异</span>
              </h4>
              <p className="text-sm text-stone-500 relative z-10">避免熬夜导致的白天精力不足。<br/><span className="text-teal-600 font-medium mt-1 inline-block">✨ 小家伙绝对没这问题！继续保持！</span></p>
            </motion.div>

            <motion.div variants={FADE_UP_ANIMATION_VARIANTS} className="bg-white p-5 rounded-xl border border-stone-100 shadow-sm relative overflow-hidden">
             <div className="absolute -right-6 -top-6 text-teal-50 opacity-50">
                <CheckCircle2 size={80} />
              </div>
              <h4 className="font-semibold text-stone-900 flex items-center gap-2 mb-2 relative z-10">
                电子产品控制
                <span className="px-2 py-0.5 bg-teal-50 text-teal-700 text-xs rounded-full">表现优异</span>
              </h4>
              <p className="text-sm text-stone-500 relative z-10">不沉迷于游戏和小视频等两大网络元凶。<br/><span className="text-teal-600 font-medium mt-1 inline-block">✨ 小家伙也没有这方面的问题！超级自律！</span></p>
            </motion.div>

            <motion.div variants={FADE_UP_ANIMATION_VARIANTS} className="bg-white p-5 rounded-xl border border-stone-100 shadow-sm">
              <h4 className="font-semibold text-stone-900 mb-2">
                适度放宽书法苛求
              </h4>
              <p className="text-sm text-stone-500">随着年龄增长，试卷题量将日益增加。如果一直过度死抠书写，容易导致答不完题，需要在这两者之间寻找平衡。</p>
            </motion.div>

            <motion.div variants={FADE_UP_ANIMATION_VARIANTS} className="bg-white p-5 rounded-xl border border-stone-100 shadow-sm">
              <h4 className="font-semibold text-stone-900 mb-2">
                培养收纳自理能力
              </h4>
              <p className="text-sm text-stone-500">家长要学会适度放手。在孩子力所能及的范围内，让她整理属于自己的物品和卫生，培养干净、整洁、利落的生活好习惯。</p>
            </motion.div>
            
            <motion.div variants={FADE_UP_ANIMATION_VARIANTS} className="bg-teal-600 p-5 rounded-xl text-white relative overflow-hidden shadow-md">
              <div className="absolute inset-0 bg-gradient-to-br from-teal-500 to-transparent"></div>
              <div className="relative z-10">
                <h4 className="font-semibold text-teal-50 mb-2">
                  家校合作核心
                </h4>
                <p className="text-sm text-teal-100">默契配合，共同重点盯防学习的<strong className="text-white font-medium mx-1">“质量”</strong>与对待学习的<strong className="text-white font-medium mx-1">“态度”</strong>。</p>
              </div>
            </motion.div>
          </div>
        </motion.section>

        {/* Final Conclusion */}
        <motion.div 
          initial={{ opacity: 0, y: 20 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ duration: 0.6 }}
          className="my-16 flex flex-col items-center justify-center p-10 bg-white rounded-3xl text-center border border-stone-100 shadow-sm relative overflow-hidden"
        >
          <div className="absolute top-0 left-0 w-full h-1 bg-gradient-to-r from-transparent via-teal-400 to-transparent"></div>
          <h2 className="text-2xl font-bold text-stone-900 mb-4">终章寄语录</h2>
          <p className="text-stone-600 max-w-xl mx-auto leading-relaxed">
            以<strong className="text-stone-900 mx-1">多元视角</strong>发掘孩子的能力与进步，
            重视<strong className="text-stone-900 mx-1">复盘的长期价值</strong>。
            我们接纳<strong className="text-stone-900 mx-1">松弛的心态</strong>，
            但也必定引导她建立<strong className="text-stone-900 mx-1">获取成就感的能力与持续的自驱力</strong>。
          </p>
          <div className="mt-8 w-12 h-1.5 bg-teal-500 rounded-full"></div>
        </motion.div>

      </main>
    </div>
  );
}

