export interface BearPalette {
 background: string; surface: string; elevated: string; soft: string; line: string;
 text: string; muted: string; cyan: string; onAccent: string;
 green: string; amber: string; coral: string; dangerSurface: string; dangerLine: string;
}
export const BRAND: BearPalette={
 background:'#05121F',surface:'#0C1F33',elevated:'#122B43',soft:'#16344D',line:'#1F4059',
 text:'#F0F9FC',muted:'#8CAEC2',cyan:'#43E7F2',onAccent:'#05202E',
 green:'#3EE08B',amber:'#F4C27B',coral:'#FF7B72',dangerSurface:'#361D26',dangerLine:'#6E3542'
};
// Native controls and custom surfaces share the IP's cyan/navy palette.
export const BEAR_THEME: CustomTheme={colors:{
 brand:BRAND.cyan,warning:BRAND.amber,alert:BRAND.coral,confirm:BRAND.cyan,
 fontPrimary:BRAND.text,fontSecondary:BRAND.muted,fontTertiary:BRAND.muted,
 fontEmphasize:BRAND.cyan,fontOnPrimary:BRAND.onAccent,
 iconPrimary:BRAND.text,iconSecondary:BRAND.muted,iconEmphasize:BRAND.cyan,
 backgroundPrimary:BRAND.background,backgroundSecondary:BRAND.surface,backgroundTertiary:BRAND.soft,
 compBackgroundPrimary:BRAND.surface,compBackgroundSecondary:BRAND.soft,
 compBackgroundTertiary:BRAND.soft,compBackgroundEmphasize:BRAND.cyan,
 compEmphasizeSecondary:BRAND.soft,compDivider:BRAND.line,
 interactiveFocus:BRAND.cyan,interactiveActive:BRAND.cyan
}};
