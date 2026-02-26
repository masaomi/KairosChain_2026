'use client';

import { useState, useEffect, useRef } from 'react';
import { useParams, useRouter } from 'next/navigation';
import Header from '@/components/layout/Header';
import AuthGuard from '@/components/layout/AuthGuard';
import ChoicePanel from '@/components/story/ChoicePanel';
import DialogueDisplay from '@/components/story/DialogueDisplay';
import TiaraAvatar from '@/components/story/TiaraAvatar';
import AffinityIndicator from '@/components/story/AffinityIndicator';
import StoryOnboarding from '@/components/story/StoryOnboarding';
import PersonalityRadar from '@/components/echo/PersonalityRadar';
import LoadingSpinner from '@/components/ui/LoadingSpinner';
import {
  getEcho,
  createStorySession,
  getStorySession,
  submitChoice,
  generateScene,
  pauseStorySession,
  resumeStorySession,
} from '@/lib/api';
import {
  Echo,
  StorySession,
  StoryScene,
  BeaconChoice,
  Affinity,
  EvolvedSkill,
} from '@/types';
import { ArrowLeft, Sparkles, BookOpen, Save, ScrollText, Check } from 'lucide-react';
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
  const [typewriterDone, setTypewriterDone] = useState(false);
  const [error, setError] = useState('');
  const [chapterEnd, setChapterEnd] = useState(false);
  const [beaconProgress, setBeaconProgress] = useState(0);
  const [saving, setSaving] = useState(false);
  const [saveConfirmed, setSaveConfirmed] = useState(false);
  const [evolvedSkills, setEvolvedSkills] = useState<EvolvedSkill[]>([]);
  const [onboardingDone, setOnboardingDone] = useState(false);
  const storyContentRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    initializeStory();
  }, [id]);

  // Determine next chapter based on completed sessions
  const determineNextChapter = (echoData: Echo): string => {
    const sessions = echoData.story_sessions || [];
    const completedChapters = sessions
      .filter((s) => s.status === 'completed')
      .map((s) => s.chapter);

    // Chapter progression: prologue → chapter_1 → chapter_2 → ...
    const chapterOrder = ['prologue', 'chapter_1', 'chapter_2', 'chapter_3'];
    for (const chapter of chapterOrder) {
      if (!completedChapters.includes(chapter)) {
        return chapter;
      }
    }
    // All done — replay last
    return chapterOrder[chapterOrder.length - 1];
  };

  const initializeStory = async () => {
    try {
      const echoData = await getEcho(id);
      setEcho(echoData);

      const nextChapter = determineNextChapter(echoData);

      // Try to create a new session, or use existing one on conflict
      try {
        const sessionData = await createStorySession(id, nextChapter);
        setSession(sessionData);
        loadSessionState(sessionData);
      } catch (err: unknown) {
        // If session already exists (409), load it — auto-resume if paused
        if (err instanceof Error && (err as Error & { session_id?: string }).session_id) {
          const existingId = (err as Error & { session_id?: string }).session_id!;
          // Auto-resume paused sessions
          try {
            await resumeStorySession(existingId);
          } catch {
            // Ignore if not paused (already active)
          }
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
      setTypewriterDone(false);
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
    } else {
      // Typewriter complete — show dialogue and inner monologues
      setTypewriterDone(true);
      setTypewriterActive(false);
    }
  }, [displayedText, typewriterActive, currentScene]);

  const skipTypewriter = () => {
    if (currentScene) {
      setDisplayedText(currentScene.narrative || '');
      setTypewriterActive(false);
      setTypewriterDone(true);
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
      setTypewriterDone(false);

      // Update choices and progress
      setChoices(result.next_choices || []);
      setChapterEnd(result.chapter_end || false);
      setBeaconProgress(result.beacon_progress || 0);

      // Show skill evolution notification
      if (result.evolved_skills && result.evolved_skills.length > 0) {
        setEvolvedSkills(result.evolved_skills);
        setTimeout(() => setEvolvedSkills([]), 5000);
      }

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
      setTypewriterDone(false);

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

  const handleSave = async () => {
    if (!session || saving) return;
    setSaving(true);
    try {
      await pauseStorySession(session.id);
      setSaveConfirmed(true);
      setTimeout(() => setSaveConfirmed(false), 2500);
    } catch (err) {
      console.error('Save failed:', err);
    } finally {
      setSaving(false);
    }
  };

  const handleSaveAndExit = async () => {
    if (!session) return;
    setSaving(true);
    try {
      await pauseStorySession(session.id);
      router.push(`/echo/${id}`);
    } catch (err) {
      console.error('Save failed:', err);
      setSaving(false);
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

      {/* Story Onboarding — shown once for first-time players */}
      {!onboardingDone && echo && (
        <StoryOnboarding
          echoName={echo.name}
          onComplete={() => setOnboardingDone(true)}
        />
      )}

      <Header />

      <main className="relative z-10 max-w-4xl mx-auto px-4 sm:px-6 lg:px-8 py-6 sm:py-8">
        {/* Top bar: back + actions + progress */}
        <div className="flex items-center justify-between mb-6">
          <Link
            href={`/echo/${id}`}
            className="inline-flex items-center gap-2 min-h-[44px] text-[#d4af37] hover:text-[#e8c547] transition-colors"
          >
            <ArrowLeft className="w-4 h-4" />
            <span className="text-sm sm:text-base">{echo.name}</span>
          </Link>

          <div className="flex items-center gap-3">
            {/* Story log button */}
            {session.scene_count > 0 && (
              <Link
                href={`/echo/${id}/story-log?session=${session.id}`}
                className="inline-flex items-center justify-center gap-1.5 min-h-[44px] min-w-[44px] text-[#b0b0b0] hover:text-[#d4af37] transition-colors text-xs sm:text-sm"
                title="物語ログを読む"
              >
                <ScrollText className="w-4 h-4" />
                <span className="hidden sm:inline">ログ</span>
              </Link>
            )}

            {/* Save button */}
            {!chapterEnd && (
              <button
                onClick={handleSave}
                disabled={saving || generatingScene}
                className="inline-flex items-center justify-center gap-1.5 min-h-[44px] min-w-[44px] text-[#b0b0b0] hover:text-[#50c878] transition-colors text-xs sm:text-sm disabled:opacity-50"
                title="セーブ"
              >
                {saveConfirmed ? (
                  <>
                    <Check className="w-4 h-4 text-[#50c878]" />
                    <span className="text-[#50c878] hidden sm:inline">保存済み</span>
                  </>
                ) : (
                  <>
                    <Save className="w-4 h-4" />
                    <span className="hidden sm:inline">セーブ</span>
                  </>
                )}
              </button>
            )}

            {/* Save & Exit */}
            {!chapterEnd && (
              <button
                onClick={handleSaveAndExit}
                disabled={saving || generatingScene}
                className="inline-flex items-center justify-center gap-1.5 px-3 py-1.5 min-h-[44px] rounded-full bg-white/5 border border-white/10 text-[#b0b0b0] hover:text-[#d4af37] hover:border-[#d4af37]/30 transition-all text-xs disabled:opacity-50"
              >
                中断する
              </button>
            )}

            {/* Progress */}
            <div className="flex items-center gap-2 ml-2">
              <BookOpen className="w-4 h-4 text-[#b0b0b0]" />
              <div className="w-16 sm:w-24 h-1.5 bg-white/10 rounded-full overflow-hidden">
                <div
                  className="h-full bg-[#d4af37] rounded-full transition-all duration-500"
                  style={{ width: `${(beaconProgress || 0) * 100}%` }}
                />
              </div>
              <span className="text-xs text-[#b0b0b0]">
                {session.scene_count}
              </span>
            </div>
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
            className="p-6 sm:p-10 min-h-80 flex flex-col"
            onClick={skipTypewriter}
          >
            {/* Narrative text with typewriter */}
            <div className="story-text text-[#f5f5f5] mb-6 leading-relaxed text-lg sm:text-xl whitespace-pre-wrap">
              {displayedText}
              {typewriterActive &&
                displayedText.length < (currentScene?.narrative || '').length && (
                  <span className="animate-pulse">▌</span>
                )}
            </div>

            {/* Dialogue — appears after typewriter completes */}
            {typewriterDone && currentScene?.dialogue && currentScene.dialogue.length > 0 && (
              <DialogueDisplay
                dialogue={currentScene.dialogue}
                visible={typewriterDone}
              />
            )}

            {/* Echo's inner voice — appears after dialogue */}
            {typewriterDone && currentScene?.echo_inner && (
              <div className="mt-6 border-l-2 border-[#d4af37]/50 pl-4">
                <p className="text-[#b0b0b0] italic text-sm sm:text-base leading-relaxed">
                  {currentScene.echo_inner}
                </p>
              </div>
            )}

            {/* Tiara's hidden thoughts — subtle, appears last */}
            {typewriterDone && currentScene?.tiara_inner && (
              <div className="mt-4 border-l-2 border-[#c0a0d0]/30 pl-4">
                <p className="text-[#806090] italic text-xs sm:text-sm leading-relaxed">
                  {currentScene.tiara_inner}
                </p>
              </div>
            )}

            {/* Affinity changes — shown after all narrative content */}
            {typewriterDone && currentScene?.affinity_delta &&
              Object.values(currentScene.affinity_delta).some((v) => v !== 0) && (
              <div className="mt-6">
                <AffinityIndicator delta={currentScene.affinity_delta} />
              </div>
            )}

            {/* Click to skip hint */}
            {typewriterActive &&
              displayedText.length < (currentScene?.narrative || '').length && (
                <p className="text-xs text-[#606060] text-center mt-4">
                  クリックしてスキップ
                </p>
              )}
          </div>
        </div>

        {/* Skill Evolution Notification */}
        {evolvedSkills.length > 0 && (
          <div className="glass-morphism rounded-2xl p-6 mb-6 border border-[#50c878]/40 animate-fade-in">
            <div className="flex items-center gap-3 mb-3">
              <Sparkles className="w-5 h-5 text-[#50c878]" />
              <span className="text-sm font-semibold text-[#50c878]">
                スキルが目覚めました
              </span>
            </div>
            {evolvedSkills.map((skill) => (
              <div key={skill.skill_id} className="ml-8 mb-2">
                <span className="text-[#d4af37] font-medium text-sm">
                  {skill.title}
                </span>
                <span className="text-[#606060] text-xs ml-2">
                  {skill.layer}
                </span>
              </div>
            ))}
          </div>
        )}

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
                  className="text-[#50c878] hover:text-[#6ae089] font-semibold text-sm sm:text-base transition-colors disabled:opacity-50 disabled:cursor-not-allowed min-h-[44px] inline-flex items-center"
                >
                  エコーに任せる
                </button>
              </div>
            )}
          </>
        )}

        {/* Loading overlay — story-themed */}
        {generatingScene && (
          <div className="fixed inset-0 bg-black/60 flex items-center justify-center z-50">
            <div className="glass-morphism rounded-2xl p-8 sm:p-10 text-center max-w-sm">
              <div className="w-12 h-12 mx-auto mb-4 relative">
                <div className="absolute inset-0 rounded-full border-2 border-[#d4af37]/30 animate-ping" />
                <div className="absolute inset-2 rounded-full border-2 border-[#50c878]/40 animate-pulse" />
                <div className="absolute inset-4 rounded-full bg-[#c0a0d0]/20" />
              </div>
              <p className="text-[#d4af37] font-serif text-base mb-2">
                呼応石が脈打っている...
              </p>
              <p className="text-[#606060] text-xs">
                物語が紡がれています
              </p>
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
          {/* KairosChain recording indicator */}
          <div className="flex items-center gap-1.5 mt-3 pt-3 border-t border-white/5">
            <div className="w-1.5 h-1.5 rounded-full bg-[#50c878] animate-pulse" />
            <p className="text-[10px] text-[#606060]">
              あなたの選択はKairosChainに記録されています
            </p>
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
