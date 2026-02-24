'use client';

import { Affinity } from '@/types';

interface PersonalityRadarProps {
  affinity?: Affinity;
  size?: 'sm' | 'md' | 'lg';
}

export default function PersonalityRadar({ affinity, size = 'md' }: PersonalityRadarProps) {
  const axes = [
    { key: 'courage', label: '勇敢さ', angle: 0 },
    { key: 'wisdom', label: '知性', angle: 72 },
    { key: 'compassion', label: '共感', angle: 144 },
    { key: 'ambition', label: '野心', angle: 216 },
    { key: 'curiosity', label: '好奇心', angle: 288 },
  ];

  const getAffinity = (key: string): number => {
    if (!affinity) return 0.5;
    const val = affinity[key as keyof Affinity] as number | undefined;
    return typeof val === 'number' ? val : 0.5;
  };

  const sizeConfig = {
    sm: { width: '150', height: '150', radius: '70' },
    md: { width: '250', height: '250', radius: '100' },
    lg: { width: '350', height: '350', radius: '150' },
  };

  const config = sizeConfig[size];
  const centerX = parseInt(config.width) / 2;
  const centerY = parseInt(config.height) / 2;
  const radius = parseInt(config.radius);

  // Generate pentagon points
  const getPoint = (angle: number, distance: number) => {
    const rad = (angle - 90) * (Math.PI / 180);
    return {
      x: centerX + distance * Math.cos(rad),
      y: centerY + distance * Math.sin(rad),
    };
  };

  // Build the data polygon
  let dataPoints = '';
  axes.forEach((axis) => {
    const val = getAffinity(axis.key);
    const point = getPoint(axis.angle, radius * val);
    dataPoints += `${point.x},${point.y} `;
  });

  // Build the grid
  const gridLevels = 5;
  const gridCircles = [];
  for (let i = 1; i <= gridLevels; i++) {
    const r = (radius / gridLevels) * i;
    let points = '';
    axes.forEach((axis) => {
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
      {/* Grid circles */}
      {gridCircles.map((points, idx) => (
        <polygon
          key={`grid-${idx}`}
          points={points}
          fill="none"
          stroke="#d4af37"
          strokeWidth="1"
          opacity="0.2"
        />
      ))}

      {/* Axis lines */}
      {axes.map((axis, idx) => {
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
        opacity="0.7"
      />

      {/* Labels */}
      {axes.map((axis) => {
        const point = getPoint(axis.angle, radius + 20);
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
