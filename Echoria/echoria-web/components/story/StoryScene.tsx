import { StoryScene as StorySceneType } from '@/types';
import { Sparkles } from 'lucide-react';

interface StorySceneProps {
  scene: StorySceneType;
  displayedText: string;
  onSkip: () => void;
}

export default function StoryScene({ scene, displayedText, onSkip }: StorySceneProps) {
  return (
    <div onClick={onSkip} className="cursor-pointer select-none">
      {/* Title */}
      {scene.title && (
        <h2 className="text-2xl sm:text-3xl font-serif font-bold text-[#d4af37] mb-6 text-center">
          {scene.title}
        </h2>
      )}

      {/* Main Narrative */}
      <div className="story-text text-[#f5f5f5] mb-8 leading-relaxed whitespace-pre-wrap">
        {displayedText}
        {displayedText.length < (scene.narrative || '').length && (
          <span className="animate-pulse">▌</span>
        )}
      </div>

      {/* Tiara's Dialogue */}
      {scene.tiaraDialogue && (
        <div className="bg-[#50c878]/10 border-l-4 border-[#50c878] rounded-r-lg p-4 mb-8 mt-8">
          <p className="text-[#50c878] font-semibold text-sm mb-2">ティアラ</p>
          <p className="text-[#f5f5f5] text-sm sm:text-base leading-relaxed">
            {scene.tiaraDialogue}
          </p>
        </div>
      )}

      {/* Echo's Action */}
      {scene.echoAction && (
        <p className="text-[#b0b0b0] italic text-sm sm:text-base border-l-2 border-[#d4af37]/50 pl-4">
          {scene.echoAction}
        </p>
      )}

      {/* Affinity Changes */}
      {scene.affinityChanges && Object.keys(scene.affinityChanges).length > 0 && (
        <div className="mt-8 bg-[#d4af37]/10 border-t border-[#d4af37]/30 pt-4">
          <div className="flex items-center gap-2 text-sm">
            <Sparkles className="w-4 h-4 text-[#d4af37]" />
            <span className="text-[#d4af37]">
              {Object.entries(scene.affinityChanges)
                .map(([key, val]) => `${key}: ${val > 0 ? '+' : ''}${val}`)
                .join(', ')}
            </span>
          </div>
        </div>
      )}

      {/* Click hint */}
      {displayedText.length < (scene.narrative || '').length && (
        <p className="text-xs text-[#606060] text-center mt-4">
          クリックしてスキップ
        </p>
      )}
    </div>
  );
}
