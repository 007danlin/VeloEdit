/// Metric widget layout: text positioning, icon placement, unit sizing, and
/// vertical-metrics helpers.
///
/// The metric row is manually laid out so icon, value, and units can each use
/// their own size while sharing one top-left anchor.
use crate::error::CoreResult;
use crate::normalize::ValidatedValueWidget;
use crate::render::text::{
    draw_text_with_vertical_metrics_text, measure_text, parse_color, ResolvedTextStyle,
};
use crate::types::DisplayType;
use skia_safe::Canvas;
use std::path::PathBuf;

pub(crate) const METRIC_WIDGET_LINE_HEIGHT: f32 = 0.92;
const METRIC_WIDGET_OUTER_GAP_PX: f32 = 8.0;
pub(crate) const METRIC_WIDGET_UNITS_GAP_PX: f32 = 8.0;
const COORDINATE_DIRECTION_GAP_PX: f32 = 8.0;
pub(crate) const MIN_UNITS_FONT_SIZE: f32 = 12.0;
pub(crate) const METRIC_WIDGET_UNIT_RATIO: f32 = 0.28;

pub const NUMERIC_VERTICAL_METRICS_TEXT: &str = "0123456789-:.%";
const COORDINATE_VERTICAL_METRICS_TEXT: &str = "NSEW88\u{00B0}88.888\u{2032}88\u{2033}";

/// Draws the icon, value text, and optional unit text for a metric widget.
///
/// All output-affecting fields are read from the pre-validated type — zero
/// backend-owned defaults are applied.
pub(crate) fn draw_metric_parts(
    canvas: &Canvas,
    base_style: &ResolvedTextStyle,
    parts: &crate::render::format::MetricDisplayParts,
    scale: f32,
    font_dirs: &[PathBuf],
    static_icon_rendered: bool,
    validated: &ValidatedValueWidget,
) -> CoreResult<()> {
    let (value_text, unit_text) = match &parts.content {
        crate::render::format::MetricDisplayContent::Coordinates(coordinate) => {
            return draw_coordinate_parts(
                canvas,
                base_style,
                coordinate,
                scale,
                font_dirs,
                static_icon_rendered,
                parts.icon_kind,
                validated,
            )
        }
        crate::render::format::MetricDisplayContent::Standard {
            value_text,
            unit_text,
        } => (value_text, unit_text.as_deref()),
    };

    let value_measure = measure_text(value_text, base_style, font_dirs)?;
    let value_vertical_measure = measure_text(
        super::metric_vertical_metrics_text(value_text),
        base_style,
        font_dirs,
    )?;
    let value_line_height = base_style.font_size * METRIC_WIDGET_LINE_HEIGHT;

    let mut units_style = base_style.clone();
    units_style.font_size =
        (base_style.font_size * METRIC_WIDGET_UNIT_RATIO).max(MIN_UNITS_FONT_SIZE * scale);
    units_style.line_height = units_style.font_size * METRIC_WIDGET_LINE_HEIGHT;
    let units_measure = unit_text
        .map(|unit_text| measure_text(unit_text, &units_style, font_dirs))
        .transpose()?;
    let units_line_height = units_style.font_size * METRIC_WIDGET_LINE_HEIGHT;

    let icon_color_hex = ColorHexSlice(validated.icon_color).to_hex_string();
    let unit_color_hex = ColorHexSlice(validated.unit_color).to_hex_string();
    let icon_size = validated.icon_size * scale;
    let show_units = unit_text.is_some();
    let show_icon = parts.show_icon && parts.icon_kind.is_some();
    let icon_margin_right = (base_style.font_size * 0.08).max(METRIC_WIDGET_OUTER_GAP_PX * scale);
    let text_group_height = if show_units {
        value_line_height.max(units_line_height)
    } else {
        value_line_height
    };
    let row_height = if show_icon {
        icon_size.max(text_group_height)
    } else {
        text_group_height
    };
    let text_group_left = if show_icon {
        icon_size + (METRIC_WIDGET_OUTER_GAP_PX * scale) + icon_margin_right
    } else {
        0.0
    };
    let text_group_top = base_style.y + ((row_height - text_group_height) * 0.5);
    let text_group_bottom = text_group_top + text_group_height;
    let value_glyph_height =
        (value_vertical_measure.bounds_bottom - value_vertical_measure.bounds_top).abs();
    let value_top = text_group_bottom - (value_line_height + value_glyph_height) * 0.5;

    let mut value_style = base_style.clone();
    value_style.x = base_style.x + text_group_left;
    value_style.y = value_top;
    value_style.line_height = value_line_height;

    if show_icon && !static_icon_rendered {
        super::icons::draw_metric_icon(
            canvas,
            parts.icon_kind,
            &icon_color_hex,
            base_style.opacity,
            base_style.shadow_color,
            base_style.shadow_strength,
            base_style.shadow_distance,
            base_style.x + validated.icon_offset_x * scale,
            metric_icon_top_from_value_layout(
                text_group_bottom,
                value_line_height,
                &value_vertical_measure,
                icon_size,
            ) + validated.icon_offset_y * scale,
            icon_size,
        );
    }

    draw_text_with_vertical_metrics_text(
        canvas,
        value_text,
        super::metric_vertical_metrics_text(value_text),
        &value_style,
        font_dirs,
    )?;

    if let (Some(unit_text), Some(unit_measure)) = (unit_text, units_measure) {
        let mut units_style = units_style;
        units_style.color = parse_color(&unit_color_hex, base_style.opacity);
        units_style.x = value_style.x + value_measure.width + (METRIC_WIDGET_UNITS_GAP_PX * scale);
        let unit_vertical_metrics_text = if unit_text == "\u{00B0}" {
            "\u{00B0}C"
        } else {
            unit_text
        };
        let unit_vertical_measure = if unit_text == unit_vertical_metrics_text {
            unit_measure
        } else {
            measure_text(unit_vertical_metrics_text, &units_style, font_dirs)?
        };
        let units_glyph_height =
            (unit_vertical_measure.bounds_bottom - unit_vertical_measure.bounds_top).abs();
        units_style.y = text_group_bottom - (units_line_height + units_glyph_height) * 0.5;
        draw_text_with_vertical_metrics_text(
            canvas,
            unit_text,
            unit_vertical_metrics_text,
            &units_style,
            font_dirs,
        )?;
    }
    Ok(())
}

/// Draws GPS coordinate lines with explicit positioning and separate direction
/// and numeric colors. The `both` mode uses two compact 40%-size rows.
fn draw_coordinate_parts(
    canvas: &Canvas,
    base_style: &ResolvedTextStyle,
    coordinate: &crate::render::format::MetricCoordinateDisplay,
    scale: f32,
    font_dirs: &[PathBuf],
    static_icon_rendered: bool,
    icon_kind: Option<crate::render::format::MetricIconKind>,
    validated: &ValidatedValueWidget,
) -> CoreResult<()> {
    let is_stacked = coordinate.lines.len() == 2;
    let coordinate_font_size = if is_stacked {
        base_style.font_size * 0.4
    } else {
        base_style.font_size
    };
    let line_height = coordinate_font_size * METRIC_WIDGET_LINE_HEIGHT;
    let line_gap = if is_stacked {
        coordinate_font_size * 0.08
    } else {
        0.0
    };
    let total_height = (line_height * coordinate.lines.len() as f32)
        + (line_gap * coordinate.lines.len().saturating_sub(1) as f32);
    let direction_gap = (coordinate_font_size * 0.08).max(COORDINATE_DIRECTION_GAP_PX * scale);
    let mut line_measurements = Vec::with_capacity(coordinate.lines.len());
    let mut value_style = base_style.clone();
    value_style.font_size = coordinate_font_size;
    value_style.line_height = line_height;
    for line in &coordinate.lines {
        let direction_measure = line
            .direction
            .as_deref()
            .map(|direction| measure_text(direction, &value_style, font_dirs))
            .transpose()?;
        let value_measure = measure_text(&line.value_text, &value_style, font_dirs)?;
        let direction_width = direction_measure.map_or(0.0, |measure| measure.width);
        line_measurements.push((direction_width, value_measure.width));
    }
    let direction_column_width = line_measurements
        .iter()
        .map(|(direction_width, _)| *direction_width)
        .fold(0.0, f32::max);
    let value_column_width = line_measurements
        .iter()
        .map(|(_, value_width)| *value_width)
        .fold(0.0, f32::max);
    let icon_color_hex = ColorHexSlice(validated.icon_color).to_hex_string();
    let unit_color_hex = ColorHexSlice(validated.unit_color).to_hex_string();
    let icon_size = validated.icon_size * scale;
    let show_icon = validated.show_icon && icon_kind.is_some();
    let text_group_left = if show_icon {
        icon_size
            + (METRIC_WIDGET_OUTER_GAP_PX * scale)
            + (base_style.font_size * 0.08).max(8.0 * scale)
    } else {
        0.0
    };
    let row_height = total_height.max(if show_icon { icon_size } else { 0.0 });
    let text_top = base_style.y + (row_height - total_height) * 0.5;

    if show_icon && !static_icon_rendered {
        super::icons::draw_metric_icon(
            canvas,
            icon_kind,
            &icon_color_hex,
            base_style.opacity,
            base_style.shadow_color,
            base_style.shadow_strength,
            base_style.shadow_distance,
            base_style.x + validated.icon_offset_x * scale,
            base_style.y + (row_height - icon_size) * 0.5 + validated.icon_offset_y * scale,
            icon_size,
        );
    }

    for (index, line) in coordinate.lines.iter().enumerate() {
        let line_y = text_top + index as f32 * (line_height + line_gap);
        let (_, value_width) = line_measurements[index];
        let line_x = base_style.x + text_group_left;
        let line_vertical_metrics_text = super::metric_vertical_metrics_text(&line.value_text);
        if let Some(direction) = line.direction.as_deref() {
            let mut direction_style = value_style.clone();
            direction_style.x = line_x;
            direction_style.y = line_y;
            direction_style.color = parse_color(&unit_color_hex, base_style.opacity);
            draw_text_with_vertical_metrics_text(
                canvas,
                direction,
                line_vertical_metrics_text,
                &direction_style,
                font_dirs,
            )?;
        }

        let mut number_style = value_style.clone();
        number_style.x = line_x
            + if direction_column_width > 0.0 {
                direction_column_width + direction_gap + (value_column_width - value_width)
            } else {
                value_column_width - value_width
            };
        number_style.y = line_y;
        draw_text_with_vertical_metrics_text(
            canvas,
            &line.value_text,
            line_vertical_metrics_text,
            &number_style,
            font_dirs,
        )?;
    }
    Ok(())
}

/// Small wrapper to present `[u8; 4]` RGBA bytes as a `#RRGGBBAA` hex string
/// for functions that still expect a `&str` colour.
struct ColorHexSlice([u8; 4]);

impl ColorHexSlice {
    fn to_hex_string(&self) -> String {
        format!(
            "#{:02x}{:02x}{:02x}{:02x}",
            self.0[0], self.0[1], self.0[2], self.0[3]
        )
    }
}

/// Returns whether a validated value contributes an icon that can be cached.
pub(crate) fn has_static_metric_icon_validated(validated: &ValidatedValueWidget) -> bool {
    if validated.display_type != DisplayType::Text {
        return false;
    }
    validated.show_icon && super::icons::metric_icon_kind_for_value(validated.metric).is_some()
}

/// Draws a static metric icon from a validated value — zero backend defaults.
pub(crate) fn draw_static_metric_icon_for_value_validated(
    canvas: &Canvas,
    validated: &ValidatedValueWidget,
    base_style: &ResolvedTextStyle,
    scale: f32,
    font_dirs: &[PathBuf],
) -> CoreResult<bool> {
    if validated.display_type != DisplayType::Text {
        return Ok(false);
    }
    let Some(icon_kind) = super::icons::metric_icon_kind_for_value(validated.metric) else {
        return Ok(false);
    };
    if !validated.show_icon {
        return Ok(false);
    }

    let icon_size = validated.icon_size * scale;
    if icon_size <= 0.0 {
        return Ok(false);
    }

    let icon_color_hex = ColorHexSlice(validated.icon_color).to_hex_string();
    let icon_top = if validated.metric == crate::MetricKind::GpsCoordinates {
        let is_stacked = validated.display_unit == "both";
        let coordinate_font_size = if is_stacked {
            base_style.font_size * 0.4
        } else {
            base_style.font_size
        };
        let coordinate_line_height = coordinate_font_size * METRIC_WIDGET_LINE_HEIGHT;
        let coordinate_line_gap = if is_stacked {
            coordinate_font_size * 0.08
        } else {
            0.0
        };
        let line_count = if is_stacked { 2.0 } else { 1.0 };
        let text_height =
            coordinate_line_height * line_count + coordinate_line_gap * (line_count - 1.0);
        let row_height = icon_size.max(text_height);
        base_style.y + (row_height - icon_size) * 0.5
    } else {
        let value_line_height = base_style.font_size * METRIC_WIDGET_LINE_HEIGHT;
        let row_height = icon_size.max(value_line_height);
        let text_group_top = base_style.y + ((row_height - value_line_height) * 0.5);
        let text_group_bottom = text_group_top + value_line_height;
        let value_vertical_measure =
            measure_text(NUMERIC_VERTICAL_METRICS_TEXT, base_style, font_dirs)?;
        metric_icon_top_from_value_layout(
            text_group_bottom,
            value_line_height,
            &value_vertical_measure,
            icon_size,
        )
    };
    super::icons::draw_metric_icon(
        canvas,
        Some(icon_kind),
        &icon_color_hex,
        base_style.opacity,
        base_style.shadow_color,
        base_style.shadow_strength,
        base_style.shadow_distance,
        base_style.x + validated.icon_offset_x * scale,
        icon_top + validated.icon_offset_y * scale,
        icon_size,
    );
    Ok(true)
}

/// Returns the text used for vertical alignment measurements.
///
/// Numeric metrics (digits, `:`, `.`, `%`, `+`, `-`) use a stable reference
/// string (`"888:88"`) so vertical layout does not jump when the displayed
/// value changes. Coordinate values use a stable reference containing the
/// direction letters and DMS/DDM symbols. Neutral gear uses the numeric
/// reference; other text passes through unchanged.
pub fn metric_vertical_metrics_text(text: &str) -> &str {
    if text.contains('\u{00B0}') && (text.contains('\u{2032}') || text.contains('\u{2033}')) {
        COORDINATE_VERTICAL_METRICS_TEXT
    } else if text == "N"
        || (!text.is_empty()
            && text
                .chars()
                .all(|ch| ch.is_ascii_digit() || matches!(ch, ':' | '.' | '%' | '+' | '-' | '/')))
    {
        NUMERIC_VERTICAL_METRICS_TEXT
    } else {
        text
    }
}

/// Computes the icon top position so the icon is visually centered on the
/// value glyphs rather than on the row line box. This matches the frontend
/// preview layout so the Rust renderer produces identical icon placement.
pub fn metric_icon_top_from_value_layout(
    text_group_bottom: f32,
    value_line_height: f32,
    value_measure: &crate::render::text::MeasuredText,
    icon_size: f32,
) -> f32 {
    let value_glyph_height = (value_measure.bounds_bottom - value_measure.bounds_top).abs();
    let value_top = text_group_bottom - (value_line_height + value_glyph_height) * 0.5;
    value_top + (value_line_height * 0.5) - (icon_size * 0.5)
}
