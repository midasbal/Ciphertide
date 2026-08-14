import shieldPortrait from '../assets/shield.jpeg'
import bombardmentPortrait from '../assets/bombardment.jpeg'
import rakePortrait from '../assets/rake.jpeg'
import salvoPortrait from '../assets/salvo.jpeg'
import carpetPortrait from '../assets/carpet.jpeg'

export type CaptainMarkKind = 'shield' | 'bombardment' | 'rake' | 'salvo' | 'carpet'

export interface Captain {
  id: number
  code: string
  /** The captain's real name, the prominent display label. */
  name: string
  /** The captain's unique signature skill, for example "Shield". */
  skillName: string
  /** Short teaser line, used on the landing page captain grid. */
  teaser: string
  /** One-line mechanic summary, used on the profile captain-select page. */
  description: string
  mark: CaptainMarkKind
  /** Portrait image, imported so Vite fingerprints it. */
  portrait: string
  /** Whether this captain starts unlocked before any player progress. */
  unlockedByDefault: boolean
  /** Salvage cost to unlock, 0 for starters. */
  cost: number
}

/**
 * The five captains, one shared roster used by both the landing teaser
 * and the profile captain-select screen so the data is never duplicated.
 * Every captain also carries Sonar and Barrage, tracked separately since
 * those two skills are the same for the whole roster.
 */
export const CAPTAINS: Captain[] = [
  {
    id: 1,
    code: 'CPT-01',
    name: 'Mara Halden',
    skillName: 'Shield',
    teaser: 'Warps a single cell against the next confirmed hit.',
    description: 'Seals a cell so the next hit that finds it breaks the shield, not the hull.',
    mark: 'shield',
    portrait: shieldPortrait,
    unlockedByDefault: true,
    cost: 0,
  },
  {
    id: 2,
    code: 'CPT-02',
    name: 'Dario Kastel',
    skillName: 'Bombardment',
    teaser: 'Saturates a fixed pattern across a wide target area.',
    description: 'Marks a 10x10 zone and strikes fifteen cells inside it at random.',
    mark: 'bombardment',
    portrait: bombardmentPortrait,
    unlockedByDefault: true,
    cost: 0,
  },
  {
    id: 3,
    code: 'CPT-03',
    name: 'Silas Crowe',
    skillName: 'Rake',
    teaser: 'Strikes the length of a chosen row in one pass.',
    description: 'Strikes three random cells along a chosen row.',
    mark: 'rake',
    portrait: rakePortrait,
    unlockedByDefault: true,
    cost: 0,
  },
  {
    id: 4,
    code: 'CPT-04',
    name: 'Ezra Locke',
    skillName: 'Salvo',
    teaser: 'Commits three chosen coordinates in a single volley.',
    description: 'Names three exact cells and hits all three, then forfeits the next turn.',
    mark: 'salvo',
    portrait: salvoPortrait,
    unlockedByDefault: false,
    cost: 600,
  },
  {
    id: 5,
    code: 'CPT-05',
    name: 'Ivo Marsh',
    skillName: 'Carpet',
    teaser: 'Saturates a small area, but only ever speaks if it lands.',
    description: 'Strikes a 3x3 block, and only leaves a mark if a ship sits inside it.',
    mark: 'carpet',
    portrait: carpetPortrait,
    unlockedByDefault: false,
    cost: 900,
  },
]
