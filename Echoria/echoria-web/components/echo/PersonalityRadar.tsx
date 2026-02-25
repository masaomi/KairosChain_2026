'use client';

import { Affinity } from '@/types';

interface PersonalityRadarProps {
  affinity?: Partial<Affinity>;
  size?: 'sm' | 'md' | 'lg';
}

// Echoria 5-axis affinity system
const AXES = [
  { key: 'tiara_trust', label: '信頼', angle: 0, min: 0, max: 100 },
  { key: 'logic_empathy_balance', label: '共感', angle: 72, min: -50, max: 50 },
  { key: 'name_memory_stability', label: '記憶', angle: 144, min: 0, max: 100 },
  { key: 'authority_resistance', label: '反抗', angle: 216, min: -50, max: 50 },
  { key: 'fragment_count', label: 'カケラ', angle: 288, min: 0, max: 50 },
];

export default function PersonalityRadar({ affinity, size = 'md' }: PersonalityRadarProps) {
  // Normalize value to 0-1 range for radar display
  const getNormalized = (key: string): number => {
    if (!affinity) return 0.5;
    const axis = AXES.find((a) => a.key === key);
    if (!axis) return 0.5;
    const val = affinity[key as keyof Affinity] as number | undefined;
    if (typeof val !== 'number') return 0.5;
    return (val - axis.min) / (axis.max - axis.min);
  };

  const sizeConfig = {
    sm: { width: '150', height: '150', radius: '55' },
    md: { width: '250', height: '250', radius: '90' },
    lg: { width: '350', height: '350', radius: '130' },
  };

  const config = sizeConfig[size];
  const centerX = parseInt(config.width) / 2;
  const centerY = parseInt(config.height) / 2;
  const radius = parseInt(config.radius);

  const getPoint = (angle: number, distance: number) => {
    const rad = (angle - 90) * (Math.PI / 180);
    return {
      x: centerX + distance * Math.cos(rad),
      y: centerY + distance * Math.sin(rad),
    };
  };

  // Data polygon
  let dataPoints = '';
  AXES.forEach((axis) => {
    const val = Math.max(0, Math.min(1, getNormalized(axis.key)));
    const point = getPoint(axis.angle, radius * val);
    dataPoints += `${point.x},${point.y} `;
  });

  // Grid pentagons
  const gridLevels = 5;
  const gridCircles = [];
  for (let i = 1; i <= gridLevels; i++) {
    const r = (radius / gridLevels) * i;
    let points = '';
    AXES.forEach((axis) => {
      const point = getPoint(axis.angle, r);
      points += `${point.x},${point.y} `;
    });
    gridCircles.push(points);
  }

  return (
    <svg
      width={config.width}
      height={config.height}
      viewBox={`0 0 ${config.width} ${config.height}`}
      className="drop-shadow-lg"
    >
      {/* Grid pentagons */}
      {gridCircles.map((points, idx) => (
        <polygon
          key={`grid-${idx}`}
          points={points}
          fill="none"
          stroke="#d4af37"
          strokeWidth="1"
          opacity="0.15"
        />
      ))}

      {/* Axis lines */}
      {AXES.map((axis, idx) => {
        const point = getPoint(axis.angle, radius);
        return (
          <line
            key={`axis-${idx}`}
            x1={centerX}
            y1={centerY}
            x2={point.x}
            y2={point.y}
            stroke="#d4af37"
            strokeWidth="1"
            opacity="0.2"
          />
        );
      })}

      {/* Data polygon */}
      <polygon
        points={dataPoints}
        fill="#50c878"
        stroke="#d4af37"
        strokeWidth="2"
        opacity="0.6"
      />

      {/* Data point dots */}
      {AXES.map((axis) => {
        const val = Math.max(0, Math.min(1, getNormalized(axis.key)));
        const point = getPoint(axis.angle, radius * val);
        return (
          <circle
            key={`dot-${axis.key}`}
            cx={point.x}
            cy={point.y}
            r="3"
            fill="#d4af37"
            opacity="0.9"
          />
        );
      })}

      {/* Labels */}
      {AXES.map((axis) => {
        const labelDistance = size === 'sm' ? radius + 15 : radius + 22;
        const point = getPoint(axis.angle, labelDistance);
        return (
          <text
            key={`label-${axis.key}`}
            x={point.x}
            y={point.y}
            textAnchor="middle"
            dominantBaseline="middle"
            className="text-xs font-semibold"
            fill="#d4af37"
          >
            {axis.label}
          </text>
        );
      })}
    </svg>
  );
}
