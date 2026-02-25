'use client';

import { useState, useEffect, useRef } from 'react';
import { useParams, useRouter } from 'next/navigation';
import Header from '@/components/layout/Header';
import AuthGuard from '@/components/layout/AuthGuard';
import ChoicePanel from '@/components/story/ChoicePanel';
import TiaraAvatar from '@/components/story/TiaraAvatar';
import AffinityIndicator from '@/components/story/AffinityIndicator';
import PersonalityRadar from '@/components/echo/PersonalityRadar';
import LoadingSpinner from '@/components/ui/LoadingSpinner';
import {
  getEcho,
  createStorySession,
  getStorySession,
  submitChoice,
  generateScene,
} from '@/lib/api';
import {
  Echo,
  StorySession,
  StoryScene,
  BeaconChoice,
  Affinity,
} from '@/types';
import { ArrowLeft, Sparkles, BookOpen } from 'lucide-react';
import Link from 'next/link';

function StoryPageContent() {
  const { id } = useParams() as { id: string };
  const router = useRouter();
  const [echo, setEcho] = useState<Echo | null>(null);
  const [session, setSession] = useState<StorySession | null>(null);
  const [currentScene, setCurrentScene] = useState<StoryScene | null>(null);
  const [choices, setChoices] = useState<BeaconChoice[]>([]);
  const [loading, setLoading] = useState(true);
  const [generatingScene, setGeneratingScene] = useState(false);
  const [displayedText, setDisplayedText] = useState('');
  const [typewriterActive, setTypewriterActive] = useState(true);
  const [error, setError] = useState('');
  const [chapterEnd, setChapterEnd] = useState(false);
  const [beaconProgress, setBeaconProgress] = useState(0);
  const storyContentRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    initializeStory();
  }, [id]);

  const initializeStory = async () => {
    try {
      const echoData = await getEcho(id);
      setEcho(echoData);

      // Try to create a new session, or use existing one on conflict
      try {
        const sessionData = await createStorySession(id, 'chapter_1');
        setSession(sessionData);
        loadSessionState(sessionData);
      } catch (err: unknown) {
        // If session already exists (409), load it
        if (err instanceof Error && (err as Error & { session_id?: string }).session_id) {
          const existingId = (err as Error & { session_id?: string }).session_id!;
          const sessionData = await getStorySession(existingId);
          setSession(sessionData);
          loadSessionState(sessionData);
        } else {
          throw err;
        }
      }
    } catch (err) {
      setError('物語の読み込みに失敗しました');
      console.error(err);
    } finally {
      setLoading(false);
    }
  };

  const loadSessionState = (sessionData: StorySession) => {
    // Set the latest scene
    if (sessionData.recent_scenes && sessionData.recent_scenes.length > 0) {
      const latest = sessionData.recent_scenes[sessionData.recent_scenes.length - 1];
      setCurrentScene(latest);
      setDisplayedText('');
      setTypewriterActive(true);
    }

    // Set choices from current beacon
    if (sessionData.current_beacon?.choices) {
      setChoices(sessionData.current_beacon.choices);
    }
  };

  // Typewriter effect
  useEffect(() => {
    if (!typewriterActive || !currentScene) return;

    const text = currentScene.narrative || '';
    if (displayedText.length < text.length) {
      const timer = setTimeout(() => {
        setDisplayedText((prev) => prev + text[prev.length]);
      }, 30);
      return () => clearTimeout(timer);
    }
  }, [displayedText, typewriterActive, currentScene]);

  const skipTypewriter = () => {
    if (currentScene) {
      setDisplayedText(currentScene.narrative || '');
      setTypewriterActive(false);
    }
  };

  const handleChoiceSelect = async (choiceIndex: number) => {
    if (!session) return;

    setGeneratingScene(true);
    setError('');

    try {
      const result = await submitChoice(session.id, choiceIndex);

      // Update session state
      setSession((prev) =>
        prev
          ? {
              ...prev,
              ...result.session,
              status: result.session.status as StorySession['status'],
              affinity: result.session.affinity,
            }
          : prev
      );

      // Display the AI-generated scene
      setCurrentScene(result.scene);
      setDisplayedText('');
      setTypewriterActive(true);

      // Update choices and progress
      setChoices(result.next_choices || []);
      setChapterEnd(result.chapter_end || false);
      setBeaconProgress(result.beacon_progress || 0);

      // Scroll to new content
      setTimeout(() => {
        storyContentRef.current?.scrollIntoView({ behavior: 'smooth' });
      }, 100);
    } catch (err) {
      setError('選択の処理に失敗しました');
      console.error(err);
    } finally {
      setGeneratingScene(false);
    }
  };

  const handleLetEchoDecide = async () => {
    if (!session) return;

    setGeneratingScene(true);
    setError('');

    try {
      const result = await generateScene(session.id);

      setCurrentScene(result.scene);
      setDisplayedText('');
      setTypewriterActive(true);

      // Refresh session state
      const refreshed = await getStorySession(session.id);
      setSession(refreshed);
      if (refreshed.current_beacon?.choices) {
        setChoices(refreshed.current_beacon.choices);
      }

      setTimeout(() => {
        storyContentRef.current?.scrollIntoView({ behavior: 'smooth' });
      }, 100);
    } catch (err) {
      setError('エコーの決定に失敗しました');
      console.error(err);
    } finally {
      setGeneratingScene(false);
    }
  };

  if (loading) {
    return (
      <div className="min-h-screen bg-gradient-to-b from-[#1a0a2e] via-[#16213e] to-[#0f3460] flex items-center justify-center">
        <LoadingSpinner />
      </div>
    );
  }

  if (!echo || !session) {
    return (
      <div className="min-h-screen bg-gradient-to-b from-[#1a0a2e] via-[#16213e] to-[#0f3460]">
        <Header />
        <main className="max-w-4xl mx-auto px-4 sm:px-6 lg:px-8 py-12">
          <Link
            href={`/echo/${id}`}
            className="inline-flex items-center gap-2 text-[#d4af37] hover:text-[#e8c547] mb-8"
          >
            <ArrowLeft className="w-4 h-4" />
            戻る
          </Link>
          <div className="glass-morphism rounded-2xl p-8 text-center">
            <p className="text-[#b0b0b0] mb-6">
              {error || '物語を読み込むことができません'}
            </p>
            <button onClick={initializeStory} className="button-primary px-6 py-3">
              もう一度試す
            </button>
          </div>
        </main>
      </div>
    );
  }

  return (
    <div className="min-h-screen bg-gradient-to-b from-[#1a0a2e] via-[#16213e] to-[#0f3460] relative">
      {/* Atmospheric background */}
      <div className="fixed inset-0 pointer-events-none">
        <div className="absolute top-20 right-20 w-72 h-72 bg-[#50c878]/5 rounded-full blur-3xl" />
        <div className="absolute bottom-20 left-20 w-96 h-96 bg-[#d4af37]/5 rounded-full blur-3xl" />
      </div>

      <Header />

      <main className="relative z-10 max-w-4xl mx-auto px-4 sm:px-6 lg:px-8 py-6 sm:py-8">
        {/* Top bar: back + progress */}
        <div className="flex items-center justify-between mb-6">
          <Link
            href={`/echo/${id}`}
            className="inline-flex items-center gap-2 text-[#d4af37] hover:text-[#e8c547] transition-colors"
          >
            <ArrowLeft className="w-4 h-4" />
            <span className="text-sm sm:text-base">{echo.name}</span>
          </Link>

          {/* Beacon progress bar */}
          <div className="flex items-center gap-2">
            <BookOpen className="w-4 h-4 text-[#b0b0b0]" />
            <div className="w-24 sm:w-32 h-1.5 bg-white/10 rounded-full overflow-hidden">
              <div
                className="h-full bg-[#d4af37] rounded-full transition-all duration-500"
                style={{ width: `${(beaconProgress || 0) * 100}%` }}
              />
            </div>
            <span className="text-xs text-[#b0b0b0]">
              {session.scene_count}シーン
            </span>
          </div>
        </div>

        {/* Beacon title */}
        {session.current_beacon?.title && (
          <h1 className="text-2xl sm:text-3xl font-serif font-bold text-[#d4af37] mb-6 text-center">
            {session.current_beacon.title}
          </h1>
        )}

        {/* Location indicator */}
        {session.current_beacon?.metadata?.location && (
          <p className="text-xs text-[#b0b0b0] text-center mb-6">
            📍 {session.current_beacon.metadata.location}
          </p>
        )}

        {/* Error */}
        {error && (
          <div className="mb-6 p-4 rounded-lg bg-red-900/20 border border-red-500/30">
            <p className="text-sm text-red-200">{error}</p>
          </div>
        )}

        {/* Story Content */}
        <div
          ref={storyContentRef}
          className="glass-morphism rounded-2xl overflow-hidden mb-8"
        >
          <div
            className="p-6 sm:p-10 min-h-80 flex flex-col justify-between"
            onClick={skipTypewriter}
          >
            <div>
              {/* Narrative text with typewriter */}
              <div className="story-text text-[#f5f5f5] mb-8 leading-relaxed text-lg sm:text-xl whitespace-pre-wrap">
                {displayedText}
                {typewriterActive &&
                  displayedText.length < (currentScene?.narrative || '').length && (
                    <span className="animate-pulse">▌</span>
                  )}
              </div>

              {/* Echo's internal reaction */}
              {currentScene?.echo_action && (
                <p className="text-[#b0b0b0] italic text-sm sm:text-base mb-8 border-l-2 border-[#d4af37]/50 pl-4">
                  {currentScene.echo_action}
                </p>
              )}
            </div>

            {/* Click to skip hint */}
            {typewriterActive &&
              displayedText.length < (currentScene?.narrative || '').length && (
                <p className="text-xs text-[#606060] text-center mt-4">
                  クリックしてスキップ
                </p>
              )}
          </div>

          {/* Affinity change indicator */}
          {currentScene?.affinity_impact &&
            Object.keys(currentScene.affinity_impact).length > 0 && (
              <AffinityIndicator delta={currentScene.affinity_impact} />
            )}
        </div>

        {/* Chapter End State */}
        {chapterEnd ? (
          <div className="glass-morphism rounded-2xl p-8 text-center mb-8">
            <Sparkles className="w-8 h-8 text-[#d4af37] mx-auto mb-4" />
            <h2 className="text-2xl font-serif text-[#d4af37] mb-4">
              第一章 完
            </h2>
            <p className="text-[#b0b0b0] mb-6">
              あなたの選択が、一つのエコーを生み出しました。
            </p>

            {/* Show final affinity radar */}
            <div className="flex justify-center mb-6">
              <PersonalityRadar affinity={session.affinity} size="md" />
            </div>

            <button
              onClick={() => router.push(`/echo/${id}`)}
              className="button-primary px-8 py-3"
            >
              エコーの誕生を見届ける
            </button>
          </div>
        ) : (
          <>
            {/* Choice Panel */}
            <ChoicePanel
              choices={choices}
              onSelect={handleChoiceSelect}
              disabled={generatingScene}
            />

            {/* Let Echo Decide */}
            {choices.length > 0 && (
              <div className="mt-6 text-center">
                <button
                  onClick={handleLetEchoDecide}
                  disabled={generatingScene}
                  className="text-[#50c878] hover:text-[#6ae089] font-semibold text-sm sm:text-base transition-colors disabled:opacity-50 disabled:cursor-not-allowed"
                >
                  エコーに任せる
                </button>
              </div>
            )}
          </>
        )}

        {/* Loading overlay */}
        {generatingScene && (
          <div className="fixed inset-0 bg-black/40 flex items-center justify-center z-50">
            <div className="glass-morphism rounded-2xl p-8 text-center">
              <LoadingSpinner />
              <p className="text-[#b0b0b0] mt-4">物語を生成中...</p>
            </div>
          </div>
        )}

        {/* Mini affinity sidebar (mobile: bottom, desktop: side) */}
        <div className="mt-8 glass-morphism rounded-2xl p-4">
          <div className="flex items-center justify-between">
            <div className="flex items-center gap-3">
              <TiaraAvatar trust={(session.affinity?.tiara_trust || 50) / 100} size="sm" />
              <div>
                <p className="text-xs text-[#b0b0b0]">ティアラとの絆</p>
                <div className="w-20 h-1.5 bg-white/10 rounded-full overflow-hidden mt-1">
                  <div
                    className="h-full bg-[#50c878] rounded-full transition-all duration-500"
                    style={{ width: `${session.affinity?.tiara_trust || 50}%` }}
                  />
                </div>
              </div>
            </div>
            <div className="text-right">
              <p className="text-xs text-[#b0b0b0]">カケラ</p>
              <p className="text-sm text-[#d4af37] font-bold">
                {session.affinity?.fragment_count || 0}
              </p>
            </div>
          </div>
        </div>
      </main>
    </div>
  );
}

export default function StoryPage() {
  return (
    <AuthGuard>
      <StoryPageContent />
    </AuthGuard>
  );
}
