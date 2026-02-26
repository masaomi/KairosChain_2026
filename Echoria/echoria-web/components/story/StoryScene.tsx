import { StoryScene as StorySceneType, Affinity } from '@/types';
import AffinityIndicator from './AffinityIndicator';

interface StorySceneProps {
  scene: StorySceneType;
  displayedText: string;
  onSkip: () => void;
}

export default function StoryScene({ scene, displayedText, onSkip }: StorySceneProps) {
  return (
    <div onClick={onSkip} className="cursor-pointer select-none">
      {/* Main Narrative */}
      <div className="story-text text-[#f5f5f5] mb-8 leading-relaxed whitespace-pre-wrap">
        {displayedText}
        {displayedText.length < (scene.narrative || '').length && (
          <span className="animate-pulse">▌</span>
        )}
      </div>

      {/* Echo's Action */}
      {scene.echo_action && (
        <p className="text-[#b0b0b0] italic text-sm sm:text-base border-l-2 border-[#d4af37]/50 pl-4">
          {scene.echo_action}
        </p>
      )}

      {/* Affinity Changes */}
      {scene.affinity_delta && Object.keys(scene.affinity_delta).length > 0 && (
        <div className="mt-8">
          <AffinityIndicator delta={scene.affinity_delta} />
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
