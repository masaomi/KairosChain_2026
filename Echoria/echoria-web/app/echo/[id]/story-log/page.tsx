'use client';

import { useState, useEffect, Suspense } from 'react';
import { useParams, useSearchParams } from 'next/navigation';
import Header from '@/components/layout/Header';
import AuthGuard from '@/components/layout/AuthGuard';
import LoadingSpinner from '@/components/ui/LoadingSpinner';
import { getEcho, getStoryLog } from '@/lib/api';
import { Echo, StoryLogResponse, StoryLogScene, DialogueLine } from '@/types';
import { ArrowLeft, BookOpen, Bookmark } from 'lucide-react';
import Link from 'next/link';

function StoryLogInner() {
  const { id } = useParams() as { id: string };
  const searchParams = useSearchParams();
  const sessionId = searchParams.get('session');

  const [echo, setEcho] = useState<Echo | null>(null);
  const [storyLog, setStoryLog] = useState<StoryLogResponse | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');

  useEffect(() => {
    loadStoryLog();
  }, [id, sessionId]);

  const loadStoryLog = async () => {
    try {
      const echoData = await getEcho(id);
      setEcho(echoData);

      if (sessionId) {
        const logData = await getStoryLog(sessionId);
        setStoryLog(logData);
      } else {
        setError('セッションIDが指定されていません');
      }
    } catch (err: any) {
      setError('物語ログの読み込みに失敗しました');
      console.error(err);
    } finally {
      setLoading(false);
    }
  };

  if (loading) {
    return (
      <div className="min-h-screen bg-gradient-to-b from-[#1a0a2e] via-[#16213e] to-[#0f3460] flex items-center justify-center">
        <LoadingSpinner />
      </div>
    );
  }

  if (!echo || !storyLog) {
    return (
      <div className="min-h-screen bg-gradient-to-b from-[#1a0a2e] via-[#16213e] to-[#0f3460]">
        <Header />
        <main className="max-w-3xl mx-auto px-4 sm:px-6 lg:px-8 py-12">
          <Link
            href={`/echo/${id}`}
            className="inline-flex items-center gap-2 text-[#d4af37] hover:text-[#e8c547] mb-8"
          >
            <ArrowLeft className="w-4 h-4" />
            戻る
          </Link>
          <div className="glass-morphism rounded-2xl p-8 text-center">
            <p className="text-[#b0b0b0]">{error || '物語ログを読み込めません'}</p>
          </div>
        </main>
      </div>
    );
  }

  const chapterTitle = storyLog.session.chapter === 'chapter_1' ? '第一章' : storyLog.session.chapter;
  const echoName = storyLog.session.echo_name;
  const partnerName = storyLog.session.partner_name || 'ティアラ';

  return (
    <div className="min-h-screen bg-gradient-to-b from-[#1a0a2e] via-[#16213e] to-[#0f3460] relative">
      {/* Background */}
      <div className="fixed inset-0 pointer-events-none">
        <div className="absolute top-40 right-10 w-96 h-96 bg-[#d4af37]/3 rounded-full blur-3xl" />
        <div className="absolute bottom-40 left-10 w-72 h-72 bg-[#9b59b6]/3 rounded-full blur-3xl" />
      </div>

      <Header />

      <main className="relative z-10 max-w-3xl mx-auto px-4 sm:px-6 lg:px-8 py-8 sm:py-12">
        {/* Navigation */}
        <Link
          href={`/echo/${id}`}
          className="inline-flex items-center gap-2 text-[#d4af37] hover:text-[#e8c547] mb-8 transition-colors"
        >
          <ArrowLeft className="w-4 h-4" />
          <span className="text-sm">{echo.name}のダッシュボード</span>
        </Link>

        {/* Title Page */}
        <div className="text-center mb-16 py-12">
          <BookOpen className="w-10 h-10 text-[#d4af37]/60 mx-auto mb-6" />
          <h1 className="text-4xl sm:text-5xl font-serif font-bold text-[#d4af37] mb-4">
            {chapterTitle}
          </h1>
          <p className="text-lg text-[#b0b0b0] font-serif italic">
            {echoName}の物語
          </p>
          <div className="mt-6 flex items-center justify-center gap-4 text-xs text-[#606060]">
            <span>{storyLog.session.scene_count} シーン</span>
            <span className="w-1 h-1 bg-[#606060] rounded-full" />
            <span>
              {new Date(storyLog.session.created_at).toLocaleDateString('ja-JP', {
                year: 'numeric',
                month: 'long',
                day: 'numeric',
              })}
            </span>
          </div>
          <div className="mt-8 w-24 h-px bg-gradient-to-r from-transparent via-[#d4af37]/50 to-transparent mx-auto" />
        </div>

        {/* Story Content */}
        <div className="space-y-2">
          {storyLog.scenes.map((scene, index) => (
            <SceneBlock
              key={scene.id}
              scene={scene}
              echoName={echoName}
              partnerName={partnerName}
              isFirst={index === 0}
              prevScene={index > 0 ? storyLog.scenes[index - 1] : null}
            />
          ))}
        </div>

        {/* End marker */}
        <div className="text-center py-16">
          <div className="w-24 h-px bg-gradient-to-r from-transparent via-[#d4af37]/50 to-transparent mx-auto mb-6" />
          {storyLog.session.status === 'completed' ? (
            <>
              <p className="text-[#d4af37] font-serif text-xl">完</p>
              <p className="text-[#606060] text-sm mt-2">
                {echoName}の{chapterTitle}はここで幕を閉じた。
              </p>
            </>
          ) : (
            <>
              <p className="text-[#b0b0b0] font-serif text-lg italic">つづく...</p>
              <Link
                href={`/echo/${id}/story`}
                className="inline-flex items-center gap-2 mt-4 text-[#d4af37] hover:text-[#e8c547] text-sm transition-colors"
              >
                <BookOpen className="w-4 h-4" />
                物語を続ける
              </Link>
            </>
          )}
        </div>
      </main>
    </div>
  );
}

// --- Scene Block Component ---
function SceneBlock({
  scene,
  echoName,
  partnerName,
  isFirst,
  prevScene,
}: {
  scene: StoryLogScene;
  echoName: string;
  partnerName: string;
  isFirst: boolean;
  prevScene: StoryLogScene | null;
}) {
  // Show beacon title as section header if it changes
  const showSectionHeader =
    scene.beacon_title && (isFirst || scene.beacon_title !== prevScene?.beacon_title);

  return (
    <div className="mb-8">
      {/* Section header (beacon transition) */}
      {showSectionHeader && (
        <div className="text-center my-10">
          {!isFirst && (
            <div className="w-16 h-px bg-[#d4af37]/30 mx-auto mb-8" />
          )}
          <h2 className="text-xl sm:text-2xl font-serif font-bold text-[#d4af37]/80">
            {scene.beacon_title}
          </h2>
          {scene.location && (
            <p className="text-xs text-[#606060] mt-1">{scene.location}</p>
          )}
        </div>
      )}

      {/* User choice (if any) — shown as a styled divider */}
      {scene.user_choice && (
        <div className="flex items-center gap-3 my-6">
          <div className="flex-1 h-px bg-[#d4af37]/20" />
          <span className="text-xs text-[#d4af37]/60 font-serif italic px-2">
            ▶ {scene.user_choice}
          </span>
          <div className="flex-1 h-px bg-[#d4af37]/20" />
        </div>
      )}

      {/* Narrative */}
      <div className="novel-text text-[#e8e8e8] leading-[2] text-base sm:text-lg font-serif whitespace-pre-wrap">
        {scene.narrative}
      </div>

      {/* Dialogue */}
      {scene.dialogue && scene.dialogue.length > 0 && (
        <div className="mt-4 space-y-3">
          {scene.dialogue.map((line: DialogueLine, i: number) => (
            <DialogueBlock key={i} line={line} echoName={echoName} partnerName={partnerName} />
          ))}
        </div>
      )}

      {/* Echo's inner voice */}
      {scene.echo_inner && (
        <div className="mt-5 pl-4 border-l-2 border-[#d4af37]/30">
          <p className="text-[#a0a0a0] italic text-sm leading-relaxed font-serif">
            {scene.echo_inner}
          </p>
        </div>
      )}

      {/* Tiara's hidden thoughts */}
      {scene.tiara_inner && (
        <div className="mt-3 pl-4 border-l-2 border-[#9b59b6]/20">
          <p className="text-[#806090]/80 italic text-xs leading-relaxed font-serif">
            {scene.tiara_inner}
          </p>
        </div>
      )}
    </div>
  );
}

// --- Dialogue Line Component ---
function DialogueBlock({ line, echoName, partnerName }: { line: DialogueLine; echoName: string; partnerName: string }) {
  const isTiara = line.speaker === partnerName || line.speaker === 'ティアラ' || line.speaker === 'Tiara';
  const isEcho = line.speaker === echoName || line.speaker === 'エコー' || line.speaker === 'Echo';

  let speakerColor = '#a8d8ea'; // NPC default
  if (isTiara) speakerColor = '#c0a0d0';
  if (isEcho) speakerColor = '#d4af37';

  return (
    <div className="text-base sm:text-lg font-serif leading-[2]">
      <span style={{ color: speakerColor }} className="font-semibold text-sm mr-1">
        {line.speaker}
      </span>
      <span className="text-[#e8e8e8]">
        「{line.text}」
      </span>
    </div>
  );
}

function StoryLogContent() {
  return (
    <Suspense
      fallback={
        <div className="min-h-screen bg-gradient-to-b from-[#1a0a2e] via-[#16213e] to-[#0f3460] flex items-center justify-center">
          <LoadingSpinner />
        </div>
      }
    >
      <StoryLogInner />
    </Suspense>
  );
}

export default function StoryLogPage() {
  return (
    <AuthGuard>
      <StoryLogContent />
    </AuthGuard>
  );
}
