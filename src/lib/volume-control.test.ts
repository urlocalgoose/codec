import {expect, test} from 'bun:test';
import {boundedVolume} from './volume-control';
test('bad saved volume cannot throw when assigned to the media element', () => {
  expect(boundedVolume('NaN')).toBe(.86);
  expect(boundedVolume(Infinity)).toBe(.86);
  expect(boundedVolume(-1)).toBe(0);
  expect(boundedVolume('2')).toBe(1);
  expect(boundedVolume('0.35')).toBe(.35);
});
