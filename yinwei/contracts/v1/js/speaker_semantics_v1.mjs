//! SpeakerSemanticsV1 — current stereo / Left-Right-Mid engine facts.

export const SpeakerSemanticsV1 = {
  input: 'stereo',
  inputChannelCount: 2,
  acousticFeeds: ['left', 'right', 'mid'],
  arrayModes: ['off', 'stereo2'],
  isDiscreteSurroundDecoder: false,
  isDiscrete71: false,
  maxVisualEmitters: 8,
  trueMultichannelRoutingInScope: false,
  extraSlotFeed: 'mid',
  visualRolesDoNotImplyRouting: [
    'center',
    'lfe',
    'rear',
    'side',
    'C',
    'LFE',
    'Ls',
    'Rs',
    'Lb',
    'Rb',
  ],
  isAcousticFeed(name) {
    const n = String(name).toLowerCase();
    return n === 'left' || n === 'right' || n === 'mid';
  },
};
