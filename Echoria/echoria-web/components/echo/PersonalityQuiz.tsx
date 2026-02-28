'use client';

import { useState } from 'react';
import { QuizAnswers, Affinity } from '@/types';

interface PersonalityQuizProps {
  partnerName: string;
  onComplete: (answers: QuizAnswers) => void;
  onSkip: () => void;
}

type AnswerKey = 'a' | 'b' | 'c';

interface QuizQuestion {
  id: keyof QuizAnswers;
  tiaraLine: string;
  prompt: string;
  choices: { key: AnswerKey; text: string }[];
}

const QUESTIONS: QuizQuestion[] = [
  {
    id: 'q1',
    tiaraLine: '......ようやく目を開けたのですね。',
    prompt: '目を覚ましたとき、最初に感じたのは——',
    choices: [
      { key: 'a', text: '「何かを忘れている」という強い確信' },
      { key: 'b', text: '周囲の光や音の心地よさ' },
      { key: 'c', text: '「ここはどこだ」という冷静な疑問' },
    ],
  },
  {
    id: 'q2',
    tiaraLine: 'ふぅん......面白い答え。もう一つ聞いてもいいですか。',
    prompt: '知らない声があなたの名前を呼んだ。あなたは——',
    choices: [
      { key: 'a', text: '声の方へ一歩を踏み出す' },
      { key: 'b', text: '黙って様子を見る' },
      { key: 'c', text: '「誰だ」と問い返す' },
    ],
  },
  {
    id: 'q3',
    tiaraLine: '......最後に、もう一つだけ。',
    prompt: '足元に、淡く光るものが落ちていた。あなたは——',
    choices: [
      { key: 'a', text: 'そっと手を伸ばす' },
      { key: 'b', text: '光の正体を観察する' },
      { key: 'c', text: '目を閉じて、光が伝える何かを感じ取ろうとする' },
    ],
  },
];

// Compute delta locally for mini result display
const ANSWER_DELTAS: Record<string, Record<string, Partial<Record<keyof Affinity, number>>>> = {
  q1: {
    a: { name_memory_stability: 10 },
    b: { logic_empathy_balance: 10 },
    c: { logic_empathy_balance: -10, name_memory_stability: 5 },
  },
  q2: {
    a: { tiara_trust: 10 },
    b: { authority_resistance: 5, tiara_trust: -5 },
    c: { authority_resistance: 10 },
  },
  q3: {
    a: { fragment_count: 1, logic_empathy_balance: 5 },
    b: { logic_empathy_balance: -5 },
    c: { logic_empathy_balance: 10, fragment_count: 1 },
  },
};

function computeResult(answers: QuizAnswers): { archetype: string; description: string } {
  const delta: Record<string, number> = {};
  for (const [qid, aid] of Object.entries(answers)) {
    const d = ANSWER_DELTAS[qid]?.[aid];
    if (d) {
      for (const [axis, val] of Object.entries(d)) {
        delta[axis] = (delta[axis] || 0) + (val || 0);
      }
    }
  }

  const empathy = (delta.logic_empathy_balance || 0);
  const stability = (delta.name_memory_stability || 0);
  const trust = (delta.tiara_trust || 0);
  const resistance = (delta.authority_resistance || 0);

  // Determine archetype from dominant traits
  if (empathy >= 10) return { archetype: '共鳴する心', description: '感情で世界を受け止め、他者との繋がりを自然に感じ取る存在。' };
  if (empathy <= -10) return { archetype: '静かな分析者', description: '冷静な観察眼で世界の構造を見抜き、論理の糸を手繰る存在。' };
  if (stability >= 10) return { archetype: '記憶の探求者', description: '失われた記憶に強く惹かれ、自己の輪郭を取り戻そうとする存在。' };
  if (trust >= 10) return { archetype: '信頼の架け橋', description: '未知の声にも心を開き、絆を結ぶことを恐れない存在。' };
  if (resistance >= 10) return { archetype: '自立の意志', description: '自らの道を切り開く強い意志を持ち、安易な答えを受け入れない存在。' };
  return { archetype: '揺らぐ存在', description: 'まだ定まらない可能性の中で、自分だけの形を探し始めている。' };
}

export default function PersonalityQuiz({ partnerName, onComplete, onSkip }: PersonalityQuizProps) {
  const [currentStep, setCurrentStep] = useState(0); // 0-2: questions, 3: result
  const [answers, setAnswers] = useState<Partial<QuizAnswers>>({});
  const [selectedAnswer, setSelectedAnswer] = useState<AnswerKey | null>(null);
  const [transitioning, setTransitioning] = useState(false);

  const handleAnswer = (key: AnswerKey) => {
    if (transitioning) return;
    setSelectedAnswer(key);
    setTransitioning(true);

    const question = QUESTIONS[currentStep];
    const newAnswers = { ...answers, [question.id]: key };
    setAnswers(newAnswers);

    setTimeout(() => {
      if (currentStep < 2) {
        setCurrentStep(currentStep + 1);
        setSelectedAnswer(null);
      } else {
        setCurrentStep(3); // show result
      }
      setTransitioning(false);
    }, 600);
  };

  const handleComplete = () => {
    onComplete(answers as QuizAnswers);
  };

  // Result screen
  if (currentStep === 3) {
    const result = computeResult(answers as QuizAnswers);

    return (
      <div className="fixed inset-0 bg-black/80 flex items-center justify-center z-50 px-4">
        <div className="glass-morphism rounded-2xl p-8 sm:p-10 max-w-md w-full animate-fade-in">
          {/* Tiara's reaction */}
          <div className="text-center mb-6">
            <div className="text-3xl mb-3">🐱</div>
            <p className="text-[#c0a0d0] text-sm font-serif italic">
              「......なるほど。あなたのことが、少しだけ分かった気がします」
            </p>
          </div>

          {/* Archetype */}
          <div className="text-center mb-6 py-4 border-y border-white/10">
            <p className="text-[#808080] text-xs mb-2">あなたの原型</p>
            <h2 className="text-2xl font-serif font-bold text-[#d4af37] mb-2">
              {result.archetype}
            </h2>
            <p className="text-[#b0b0b0] text-sm leading-relaxed">
              {result.description}
            </p>
          </div>

          <p className="text-[#606060] text-xs text-center mb-6">
            この傾向は物語を通じて変化していきます
          </p>

          <button
            onClick={handleComplete}
            className="w-full button-primary py-3 text-base"
          >
            物語を始める
          </button>
        </div>
      </div>
    );
  }

  // Question screen
  const question = QUESTIONS[currentStep];

  return (
    <div className="fixed inset-0 bg-black/80 flex items-center justify-center z-50 px-4">
      <div className="glass-morphism rounded-2xl p-8 sm:p-10 max-w-md w-full">
        {/* Progress */}
        <div className="flex items-center justify-between mb-6">
          <div className="flex gap-1.5">
            {QUESTIONS.map((_, idx) => (
              <div
                key={idx}
                className={`h-1 rounded-full transition-all duration-300 ${
                  idx <= currentStep ? 'w-8 bg-[#d4af37]' : 'w-4 bg-white/10'
                }`}
              />
            ))}
          </div>
          <button
            onClick={onSkip}
            className="text-xs text-[#606060] hover:text-[#808080] transition-colors"
          >
            スキップ
          </button>
        </div>

        {/* Tiara's line */}
        <div className="flex items-start gap-3 mb-6">
          <div className="flex-shrink-0 w-8 h-8 rounded-full bg-gradient-to-br from-[#9b59b6] to-[#c0a0d0] flex items-center justify-center text-sm">
            🐱
          </div>
          <div className="glass-morphism rounded-lg rounded-bl-none px-4 py-2">
            <p className="text-xs text-[#c0a0d0] mb-0.5">{partnerName}</p>
            <p className="text-[#e8e8e8] text-sm font-serif">{question.tiaraLine}</p>
          </div>
        </div>

        {/* Question */}
        <p className="text-[#d4af37] text-lg font-serif font-bold mb-6 text-center">
          {question.prompt}
        </p>

        {/* Choices */}
        <div className="space-y-3">
          {question.choices.map((choice) => (
            <button
              key={choice.key}
              onClick={() => handleAnswer(choice.key)}
              disabled={transitioning}
              className={`w-full text-left px-5 py-4 rounded-xl border transition-all duration-300 ${
                selectedAnswer === choice.key
                  ? 'bg-[#d4af37]/20 border-[#d4af37]/50 text-[#e8c547]'
                  : 'bg-white/5 border-white/10 text-[#e8e8e8] hover:bg-white/10 hover:border-white/20'
              } disabled:cursor-not-allowed`}
            >
              <span className="text-sm leading-relaxed">{choice.text}</span>
            </button>
          ))}
        </div>
      </div>
    </div>
  );
}
