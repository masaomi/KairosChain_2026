'use client';

import { useState, useEffect, useRef } from 'react';
import { useParams, useRouter } from 'next/navigation';
import Header from '@/components/layout/Header';
import AuthGuard from '@/components/layout/AuthGuard';
import StoryScene from '@/components/story/StoryScene';
import ChoicePanel from '@/components/story/ChoicePanel';
import TiaraAvatar from '@/components/story/TiaraAvatar';
import LoadingSpinner from '@/components/ui/LoadingSpinner';
import { getEcho, startStory, submitChoice, generateScene } from '@/lib/api';
import { Echo, StoryScene as StorySceneType, Choice } from '@/types';
import { ArrowLeft, Sparkles } from 'lucide-react';
import Link from 'next/link';

function StoryPageContent() {
  const { id } = useParams() as { id: string };
  const router = useRouter();
  const [echo, setEcho] = useState<Echo | null>(null);
  const [scene, setScene] = useState<StorySceneType | null>(null);
  const [loading, setLoading] = useState(true);
  const [generatingScene, setGeneratingScene] = useState(false);
  const [displayedText, setDisplayedText] = useState('');
  const [typewriterActive, setTypewriterActive] = useState(true);
  const [error, setError] = useState('');
  const storyContentRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    initializeStory();
  }, [id]);

  const initializeStory = async () => {
    try {
      const echoData = await getEcho(id);
      setEcho(echoData);

      // Get or start story session
      try {
        const sceneData = await startStory(id);
        setScene(sceneData);
        setDisplayedText('');
      } catch (err) {
        console.error('Error starting story:', err);
        setError('物語の読み込みに失敗しました');
      }
    } catch (err: any) {
      setError('エコーの読み込みに失敗しました');
      console.error(err);
    } finally {
      setLoading(false);
    }
  };

  // Typewriter effect
  useEffect(() => {
    if (!typewriterActive || !scene) return;

    if (displayedText.length < (scene.narrative || '').length) {
      const timer = setTimeout(() => {
        setDisplayedText((prev) => prev + (scene.narrative || '')[prev.length]);
      }, 30);

      return () => clearTimeout(timer);
    }
  }, [displayedText, typewriterActive, scene]);

  const skipTypewriter = () => {
    if (scene) {
      setDisplayedText(scene.narrative || '');
      setTypewriterActive(false);
    }
  };

  const handleChoiceSelect = async (choiceIndex: number) => {
    if (!scene || !scene.choices || choiceIndex >= scene.choices.length) return;

    setGeneratingScene(true);
    setError('');

    try {
      const choice = scene.choices[choiceIndex];
      const nextScene = await submitChoice(id, scene.id, choice.id);

      setScene(nextScene);
      setDisplayedText('');
      setTypewriterActive(true);

      // Scroll to story content
      setTimeout(() => {
        storyContentRef.current?.scrollIntoView({ behavior: 'smooth' });
      }, 100);
    } catch (err: any) {
      setError('選択の処理に失敗しました');
      console.error(err);
    } finally {
      setGeneratingScene(false);
    }
  };

  const handleLetEchoDecide = async () => {
    if (!scene) return;

    setGeneratingScene(true);
    setError('');

    try {
      // Call an API that lets Echo make the decision
      const nextScene = await generateScene(id, 'auto');

      setScene(nextScene);
      setDisplayedText('');
      setTypewriterActive(true);

      setTimeout(() => {
        storyContentRef.current?.scrollIntoView({ behavior: 'smooth' });
      }, 100);
    } catch (err: any) {
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

  if (!echo || !scene) {
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
            <p className="text-[#b0b0b0] mb-6">物語を読み込むことができません</p>
            <button
              onClick={initializeStory}
              className="button-primary px-6 py-3"
            >
              もう一度試す
            </button>
          </div>
        </main>
      </div>
    );
  }

  return (
    <div className="min-h-screen bg-gradient-to-b from-[#1a0a2e] via-[#16213e] to-[#0f3460] relative">
      {/* Atmospheric background based on scene mood */}
      <div
        className="fixed inset-0 pointer-events-none transition-colors duration-1000"
        style={{
          background:
            scene.mood === 'dark'
              ? 'radial-gradient(ellipse at center, #1a0a2e 0%, #0a0a1a 100%)'
              : scene.mood === 'peaceful'
                ? 'radial-gradient(ellipse at center, #1a0a2e 0%, #16213e 100%)'
                : 'radial-gradient(ellipse at center, #1a0a2e 0%, #1a1033 100%)',
        }}
      />

      {/* Accent lights */}
      <div className="fixed inset-0 pointer-events-none">
        <div className="absolute top-20 right-20 w-72 h-72 bg-[#50c878]/5 rounded-full blur-3xl" />
        <div className="absolute bottom-20 left-20 w-96 h-96 bg-[#d4af37]/5 rounded-full blur-3xl" />
      </div>

      <Header />

      {/* Main Content */}
      <main className="relative z-10 max-w-4xl mx-auto px-4 sm:px-6 lg:px-8 py-6 sm:py-8">
        {/* Back Button */}
        <Link
          href={`/echo/${id}`}
          className="inline-flex items-center gap-2 text-[#d4af37] hover:text-[#e8c547] mb-6 transition-colors"
        >
          <ArrowLeft className="w-4 h-4" />
          <span className="text-sm sm:text-base">{echo.name}</span>
        </Link>

        {/* Story Title */}
        {scene.title && (
          <h1 className="text-3xl sm:text-4xl font-serif font-bold text-[#d4af37] mb-8 text-center">
            {scene.title}
          </h1>
        )}

        {/* Error Message */}
        {error && (
          <div className="mb-6 p-4 rounded-lg bg-red-900/20 border border-red-500/30">
            <p className="text-sm text-red-200">{error}</p>
          </div>
        )}

        {/* Story Content Area */}
        <div
          ref={storyContentRef}
          className="glass-morphism rounded-2xl overflow-hidden mb-8"
        >
          {/* Scene Narrative */}
          <div
            className="p-6 sm:p-10 min-h-80 flex flex-col justify-between"
            onClick={skipTypewriter}
          >
            <div>
              {/* Main Story Text */}
              <div className="story-text text-[#f5f5f5] mb-8 leading-relaxed text-lg sm:text-xl whitespace-pre-wrap">
                {displayedText}
                {typewriterActive && displayedText.length < (scene.narrative || '').length && (
                  <span className="animate-pulse">▌</span>
                )}
              </div>

              {/* Tiara's Dialogue */}
              {scene.tiaraDialogue && (
                <div className="bg-[#50c878]/10 border-l-4 border-[#50c878] rounded-r-lg p-4 mb-8 mt-8">
                  <div className="flex items-start gap-3">
                    <TiaraAvatar trust={echo.affinity?.tiaraAffinity || 0.5} />
                    <div>
                      <p className="text-[#50c878] font-semibold text-sm mb-2">ティアラ</p>
                      <p className="text-[#f5f5f5] text-sm sm:text-base leading-relaxed">
                        {scene.tiaraDialogue}
                      </p>
                    </div>
                  </div>
                </div>
              )}

              {/* Echo's Reaction */}
              {scene.echoAction && (
                <p className="text-[#b0b0b0] italic text-sm sm:text-base mb-8 border-l-2 border-[#d4af37]/50 pl-4">
                  {scene.echoAction}
                </p>
              )}
            </div>

            {/* Click to continue hint */}
            {!generatingScene && typewriterActive && displayedText.length < (scene.narrative || '').length && (
              <p className="text-xs text-[#606060] text-center mt-4">
                クリックしてスキップ
              </p>
            )}
          </div>

          {/* Affinity Change Indicator */}
          {scene.affinityChanges && Object.keys(scene.affinityChanges).length > 0 && (
            <div className="bg-[#d4af37]/10 border-t border-[#d4af37]/30 p-4 text-center">
              <div className="flex items-center justify-center gap-2">
                <Sparkles className="w-4 h-4 text-[#d4af37]" />
                <span className="text-sm text-[#d4af37]">
                  {Object.entries(scene.affinityChanges)
                    .map(([key, val]) => `${key}: ${val > 0 ? '+' : ''}${val}`)
                    .join(', ')}
                </span>
              </div>
            </div>
          )}
        </div>

        {/* Choice Panel */}
        <ChoicePanel
          choices={scene.choices || []}
          onSelect={handleChoiceSelect}
          disabled={generatingScene}
        />

        {/* Let Echo Decide Button */}
        {scene.choices && scene.choices.length > 0 && (
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

        {/* Loading State */}
        {generatingScene && (
          <div className="fixed inset-0 bg-black/40 flex items-center justify-center z-50 rounded-2xl">
            <div className="glass-morphism rounded-2xl p-8 text-center">
              <LoadingSpinner />
              <p className="text-[#b0b0b0] mt-4">物語を生成中...</p>
            </div>
          </div>
        )}
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
