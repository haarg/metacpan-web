.PHONY: all help sprites clean-sprites

all: help

help:
	@echo targets: sprites clean-sprites

IMAGE_URL  = /static/images/
IMAGE_ROOT = root$(IMAGE_URL)
LESS_ROOT  = root/static/less/
SPRITE_TEMPLATE = root/sprite.less.template

# apt-get install optipng
PNG_OPTIM  = optipng -o7

# apt-get install libcairo2-dev libjpeg8-dev libpango1.0-dev libgif-dev
# npm install -g css-sprite
SPRITE     = css-sprite --orientation binary-tree --margin 0 \
             --css-image-path $(IMAGE_URL) --template $(SPRITE_TEMPLATE)

sprites: $(LESS_ROOT)/profile-sprite.less $(LESS_ROOT)/flag-sprite.less
clean-sprites:
	rm -rf $(LESS_ROOT)/profile-sprite.less $(LESS_ROOT)/flag-sprite.less \
		$(IMAGE_ROOT)/profile-sprite.png $(IMAGE_ROOT)/flag-sprite.png

$(LESS_ROOT)/profile-sprite.less: $(IMAGE_ROOT)/profile-sprite.png
$(LESS_ROOT)/flag-sprite.less: $(IMAGE_ROOT)/flag-sprite.png

$(IMAGE_ROOT)/profile-sprite.png: $(SPRITE_TEMPLATE) $(IMAGE_ROOT)/profile/*.png
	$(SPRITE) $(@D) --name $(@F) $(IMAGE_ROOT)/profile/*.png --style $(LESS_ROOT)/profile-sprite.less --prefix profile
	$(PNG_OPTIM) $@

$(IMAGE_ROOT)/flag-sprite.png: $(SPRITE_TEMPLATE) $(IMAGE_ROOT)/flag/*.png
	$(SPRITE) $(@D) --name $(@F) $(IMAGE_ROOT)/flag/*.png --style $(LESS_ROOT)/flag-sprite.less --prefix flag
	$(PNG_OPTIM) $@
