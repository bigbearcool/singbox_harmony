export interface BearPalette {
 background: string; surface: string; soft: string; line: string;
 text: string; muted: string; cyan: string; onAccent: string;
 coral: string; dangerSurface: string; dangerLine: string;
}
export const BRAND: BearPalette={
 background:'#061526',surface:'#0D2438',soft:'#15354A',line:'#24485C',
 text:'#EDF8FC',muted:'#A0BCCB',cyan:'#43E7F2',onAccent:'#062330',
 coral:'#FF8F86',dangerSurface:'#3B252E',dangerLine:'#75404A'
};
// Native controls and custom surfaces share the IP's cyan/navy palette.
export const BEAR_THEME: CustomTheme={colors:{
 brand:BRAND.cyan,warning:'#F4C27B',alert:BRAND.coral,confirm:BRAND.cyan,
 fontPrimary:BRAND.text,fontSecondary:BRAND.muted,fontTertiary:BRAND.muted,
 fontEmphasize:BRAND.cyan,fontOnPrimary:BRAND.onAccent,
 iconPrimary:BRAND.text,iconSecondary:BRAND.muted,iconEmphasize:BRAND.cyan,
 backgroundPrimary:BRAND.background,backgroundSecondary:BRAND.surface,backgroundTertiary:BRAND.soft,
 compBackgroundPrimary:BRAND.surface,compBackgroundSecondary:BRAND.soft,
 compBackgroundTertiary:BRAND.soft,compBackgroundEmphasize:BRAND.cyan,
 compEmphasizeSecondary:BRAND.soft,compDivider:BRAND.line,
 interactiveFocus:BRAND.cyan,interactiveActive:BRAND.cyan
}};
