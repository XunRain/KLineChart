--!strict
-- Shared layout metrics, text defaults, and the sentinel used to clear
-- optional configuration fields back to nil.

local Types = require(script.Parent.Parent.Types)

local Constants = {}

Constants.None = table.freeze({}) :: any

Constants.DEFAULT_FONT = Font.fromName("BuilderSans", Enum.FontWeight.Medium)
Constants.DEFAULT_TEXT_SIZE = 12

Constants.LEGEND_HEIGHT = 22
Constants.TITLE_HEIGHT = 24
Constants.AXIS_TITLE_HEIGHT = 18
Constants.HOVER_HITBOX_SIZE = 18
Constants.X_LABEL_WIDTH = 64
Constants.SERIES_DELAY = 0.1
Constants.MIN_CANVAS_SIZE = 2
Constants.MIN_PLOT_SIZE = 2
Constants.MAX_FILL_STRIPS = 200
Constants.MAX_POINTS_PER_PATH = 100

function Constants.font(theme: Types.Theme): Font
	return theme.font or Constants.DEFAULT_FONT
end

function Constants.textSize(theme: Types.Theme): number
	return theme.textSize or Constants.DEFAULT_TEXT_SIZE
end

return Constants
